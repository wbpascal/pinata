defmodule Replay.Masks do
  @moduledoc """
  Global mask and handle lists of the replay harness (ADR 0008) and the resolution of field paths to byte ranges.

  A mask `{module, path, reason}` excludes a field from the byte comparison. A handle `{module, path, namespace,
  reason}` is a field whose value the server picks anew in each run; the harness maps the captured value to the
  received one. A path is a field name or a list of names through nested structs and arrays. Every entry needs a
  reason. Ranges are whole bytes, a `bits` field masks its whole byte.
  """

  @type path :: atom() | [atom()]
  @type mask :: {module(), path(), reason :: String.t()}
  @type handle :: {module(), path(), namespace :: atom(), reason :: String.t()}

  # The other entries of ADR 0008 (login tokens, addresses in 0x1003 / 0x180A, uninitialised memory with its bug id)
  # are added by the issue that defines each packet; the 0x0C0C entries exist.
  @doc "Masks that apply to every replay."
  @spec global() :: [mask()]
  def global,
    do: [
      {Proto.Packets.MiscSeedAck, :seed, "session value: the seed is drawn at random per connection"},
      {Proto.Packets.UserClientWrongversionCheckAck, :unused,
       "uninitialised memory (L00-B1): the original never writes this byte, the rebuild sends 0"},
      {Proto.Packets.UserWorldselectAck, :ip,
       "server address: the capture has the LAN address of the original server, the rebuild sends public_host"},
      {Proto.Packets.UserWorldselectAck, :validate,
       "session value: the validation key is drawn at random per select; on a refusal the original sends uninitialised memory (P02-B23), the rebuild sends 0"}
    ]

  # Handles (identifiers, item keys) are added by the issue that defines each packet.
  @doc "Handles that apply to every replay."
  @spec handles() :: [handle()]
  def handles,
    do: [
      {Proto.Packets.UserWillWorldSelectAck, :otp, :login_token,
       "session value: the login token is drawn at random per request"},
      {Proto.Packets.UserWorldselectAck, :validate, :world_key,
       "session value: the key is drawn at random per select, the client sends it back in 0x0C0F"},
      {Proto.Packets.UserLoginworldReq, :validate, :world_key, "session value: the key of 0x0C0C"},
      {Proto.Packets.UserLoginWithOtpReq, :otp, :login_token,
       "session value: the client sends back the token of 0x0C34"}
    ]

  @doc "Raises `ArgumentError` for an empty reason or a first path element that is not a field of the packet."
  @spec validate!([mask() | handle()]) :: :ok
  def validate!(entries) do
    Enum.each(entries, fn entry ->
      {mod, path, reason} = {elem(entry, 0), elem(entry, 1), elem(entry, tuple_size(entry) - 1)}

      if not (is_binary(reason) and reason != ""),
        do: raise(ArgumentError, "mask or handle #{inspect(mod)} #{inspect(path)} needs a reason")

      [name | _] = List.wrap(path)

      if not List.keymember?(mod.__packet__().layout, name, 0),
        do: raise(ArgumentError, "#{inspect(mod)} has no field #{inspect(name)}")
    end)
  end

  @doc "The `{offset, size}` byte ranges of a path in a payload (several for a path through an array)."
  @spec ranges(module(), path(), binary()) :: [{non_neg_integer(), non_neg_integer()}]
  def ranges(mod, path, payload), do: walk(mod, List.wrap(path), payload, 0)

  defp walk(mod, [name | rest], payload, base) do
    {^name, off, size, sub} =
      List.keyfind(mod.__packet__().layout, name, 0) ||
        raise ArgumentError, "#{inspect(mod)} has no field #{inspect(name)}"

    at = base + off

    case {rest, sub} do
      {[], {:array, _elem, _count_bytes}} ->
        [{at, byte_size(payload) - at}]

      {[], _} ->
        [{at, size}]

      {_, {:array, elem, count_bytes}} ->
        elem_size = elem.__packet__().size
        first = at + count_bytes

        for i <- 0..(div(byte_size(payload) - first, elem_size) - 1)//1,
            r <- walk(elem, rest, payload, first + i * elem_size),
            do: r

      {_, nested} when is_atom(nested) and not is_nil(nested) ->
        walk(nested, rest, payload, at)

      {_, nil} ->
        raise ArgumentError, "#{inspect(mod)} field #{inspect(name)} is a scalar, path continues with #{inspect(rest)}"
    end
  end
end
