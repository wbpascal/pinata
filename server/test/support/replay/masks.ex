defmodule Replay.Masks do
  @moduledoc """
  Global mask and handle lists of the replay harness (ADR 0008) and the resolution of field paths to byte ranges.

  A mask `{module, path, reason}` excludes a field from the byte comparison. A handle `{module, path, namespace,
  reason}` is a field whose value the server picks anew in each run; the harness maps the captured value to the
  received one. A path is a field name or a list of names through nested structs and arrays. Every entry needs a
  reason. Ranges are whole bytes, a `bits` field masks its whole byte.

  The handle namespace `:object` is bound per map (the map of a connection comes from `map_names/0`); `0xFFFF` in
  a 2-byte `:object` field means "no object" and passes unmapped. Every other namespace is global.
  """

  @type path :: atom() | [atom()]
  @type mask :: {module(), path(), reason :: String.t()}
  @type handle :: {module(), path(), namespace :: atom(), reason :: String.t()}

  # The other entries of ADR 0008 (the address in 0x180A, uninitialised memory with its bug id) are added by the
  # issue that defines each packet; the 0x0C0C and 0x1003 addresses and the 0x0C14 and 0x1110 entries are masks.
  @doc "Masks that apply to every replay."
  @spec global() :: [mask()]
  def global,
    do:
      [
        {Proto.Packets.MiscSeedAck, :seed, "session value: the seed is drawn at random per connection"},
        {Proto.Packets.UserClientWrongversionCheckAck, :unused,
         "uninitialised memory (L00-B1): the original never writes this byte, the rebuild sends 0"},
        {Proto.Packets.UserWorldselectAck, :ip,
         "server address: the capture has the LAN address of the original server, the rebuild sends public_host"},
        {Proto.Packets.CharLoginAck, :zone_ip,
         "server address: the capture has the LAN address of the original Zone, the rebuild sends the public_host of the Zone node"},
        {Proto.Packets.CharLoginAck, :zone_port,
         "server address: the Zone node of this topology listens on another port than the capture's"},
        {Proto.Packets.CharTutorialPopupReq, :unused,
         "uninitialised memory (P02-B28): the original never writes this byte, the rebuild sends 0"}
      ] ++
        delinfo_masks() ++
        [
          {Proto.Packets.UserLoginworldAck, [:avatars, :kq_date_unused],
           "uninitialised memory (P02-B7): the two bits above the Kingdom Quest date keep old buffer bits, the rebuild sends 0; the mask covers the whole byte, so the seconds are not compared"},
          {Proto.Packets.AvatarCreatesuccAck, [:avatars, :kq_date_unused],
           "uninitialised memory (P02-B7): the two bits above the creation date keep old buffer bits, the rebuild sends 0; the mask covers the whole byte, so the seconds are not compared (the original stores the database time, in capture 37 one second after the request)"}
        ]

  defp delinfo_masks do
    for field <- [:month, :day, :hour, :min] do
      {Proto.Packets.UserLoginworldAck, [:avatars, :delinfo, field],
       "uninitialised memory (P02-B1): the original writes only the first delinfo byte of a character that is not deleted, the rebuild sends 0"}
    end
  end

  # Handles (identifiers, item keys) are added by the issue that defines each packet; the login token, the world key
  # (0x0C0C / 0x0C0F) and the 0x0C14 session handle are handles.
  @doc "Handles that apply to every replay."
  @spec handles() :: [handle()]
  def handles,
    do: [
      {Proto.Packets.UserWillWorldSelectAck, :otp, :login_token,
       "session value: the login token is drawn at random per request"},
      {Proto.Packets.UserWorldselectAck, :validate, :world_key,
       "session value: the key is drawn at random per select and the client sends it back in 0x0C0F; on a refusal the original sends uninitialised memory (P02-B23), the rebuild sends 0"},
      {Proto.Packets.UserLoginworldReq, :validate, :world_key, "session value: the key of 0x0C0C"},
      {Proto.Packets.UserLoginWithOtpReq, :otp, :login_token,
       "session value: the client sends back the token of 0x0C34"},
      {Proto.Packets.UserLoginworldAck, :worldmanager, :wm_session,
       "session handle: the original takes it from its session pool, the rebuild counts per world"},
      {Proto.Packets.AvatarCreatesuccAck, [:avatars, :chrregnum], :character,
       "identifier: the character number comes from the database sequence"}
    ]

  # The Zone entry packet with the captured map name is added by the issue that defines it.
  @doc "The server packets whose field is the map name a connection is on."
  @spec map_names() :: [{module(), path()}]
  def map_names, do: []

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
