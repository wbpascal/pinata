defmodule Replay.Deferrals do
  @moduledoc """
  Deferrals of the replay harness (ADR 0008, `GLOSSARY.md`): parts of a capture that the rebuild does not reproduce
  yet. Every entry names a milestone and a reason, and the milestone that builds the part removes the entry.

  Forms (`entry/0`): `{:payload, module, path | :all, milestone, reason}` (a field, or the whole payload, of a
  server packet is not compared), `{:payload, [index, ...], module, path | :all, milestone, reason}` (the same for
  the server packets of these transcript indices only), `{:absent, module, milestone, reason}` (the server packet is not sent yet),
  `{:absent, [index, ...], milestone, reason}` (these server packets are left out, by transcript index: for an opcode
  that built code also sends),
  `{:unsent, client_index, answer_indices, milestone, reason}` (a client packet and its answers are left out, by
  transcript index), `{:mobs, mobs, milestone, reason}` (the monsters of a map are left out per object) and
  `{:extra, module, milestone, reason}` (the rebuild sends server packets of that module the capture does not have at
  that place, a placeholder for an empty list the original leaves out; they are dropped).

  A `lists` entry of `:mobs` is `{module, array, handle_field, mob_id_field, max}`: the elements of a list packet
  that are monsters are taken out. Then a run of consecutive kept list packets of one connection (same opcode) has
  its elements concatenated and split again into lists of at most `max`; chunk *i* takes the place (index, time,
  scope) of packet *i* of the run, run packets left without a chunk are taken out. The reason: the original fills a
  list with NPCs and monsters, the rebuild only with NPCs, so the list borders differ until milestone 4.
  """

  alias Replay.Masks

  @type mobs :: %{
          appear: [{module(), handle :: Masks.path(), mob_id :: Masks.path()}],
          lists: [{module(), array :: atom(), handle :: atom(), mob_id :: atom(), max :: pos_integer()}],
          gone: [{module(), handle :: Masks.path()}],
          about: [{module(), Masks.path()}],
          npc?: (map :: String.t() | nil, mob_id :: non_neg_integer() -> boolean())
        }

  @type entry ::
          {:payload, module(), Masks.path() | :all, milestone :: pos_integer(), reason :: String.t()}
          | {:payload, [pos_integer()], module(), Masks.path() | :all, pos_integer(), String.t()}
          | {:absent, module(), pos_integer(), String.t()}
          | {:absent, [pos_integer()], pos_integer(), String.t()}
          | {:unsent, client_index :: pos_integer(), answer_indices :: [pos_integer()], pos_integer(), String.t()}
          | {:mobs, mobs(), pos_integer(), String.t()}
          | {:extra, module(), pos_integer(), String.t()}

  # Entries are added by the issue that defines each packet.
  @doc "Deferrals that apply to every replay."
  @spec global() :: [entry()]
  def global, do: []

  @doc "Raises `ArgumentError` for a malformed entry; `packets` are the transcript packets."
  @spec validate!([entry()], [Replay.Transcript.packet()]) :: :ok
  def validate!(entries, packets) do
    Enum.each(entries, fn entry ->
      check_common!(entry)
      check_shape!(entry, packets)
    end)
  end

  defp check_common!(entry) when is_tuple(entry) and tuple_size(entry) >= 4 do
    reason = elem(entry, tuple_size(entry) - 1)
    milestone = elem(entry, tuple_size(entry) - 2)

    if not (is_binary(reason) and reason != ""),
      do: raise(ArgumentError, "deferral #{inspect(elem(entry, 0))} needs a reason")

    if not (is_integer(milestone) and milestone > 0),
      do: raise(ArgumentError, "deferral #{inspect(elem(entry, 0))} needs a milestone number above 0")
  end

  defp check_common!(entry), do: raise(ArgumentError, "malformed deferral #{inspect(entry)}")

  defp check_shape!({:payload, _mod, :all, _m, _r}, _packets), do: :ok
  defp check_shape!({:payload, mod, path, _m, r}, _packets) when is_atom(mod), do: Masks.validate!([{mod, path, r}])
  defp check_shape!({:absent, mod, _m, _r}, _packets) when is_atom(mod), do: :ok
  defp check_shape!({:extra, mod, _m, _r}, _packets) when is_atom(mod), do: :ok

  defp check_shape!({:payload, indices, mod, path, _m, r}, packets) when is_list(indices) and is_atom(mod) do
    for index <- indices,
        not Enum.any?(packets, &(&1.index == index and &1.dir == :server and &1.opcode == mod.opcode())),
        do:
          raise(ArgumentError, "deferral :payload #{inspect(index)} is not a #{inspect(mod)} packet of the transcript")

    if path == :all, do: :ok, else: Masks.validate!([{mod, path, r}])
  end

  defp check_shape!({:absent, indices, _m, _r}, packets) when is_list(indices) do
    for index <- indices,
        not Enum.any?(packets, &(&1.index == index and &1.dir == :server)),
        do: raise(ArgumentError, "deferral :absent #{inspect(index)} is not a server packet of the transcript")

    :ok
  end

  defp check_shape!({:unsent, client, answers, _m, _r}, packets) when is_list(answers) do
    if not Enum.any?(packets, &(&1.index == client and &1.dir == :client)),
      do: raise(ArgumentError, "deferral :unsent #{client} is not a client packet of the transcript")

    for index <- answers,
        not Enum.any?(packets, &(&1.index == index and &1.dir == :server)),
        do: raise(ArgumentError, "deferral :unsent answer #{inspect(index)} is not a server packet of the transcript")

    :ok
  end

  defp check_shape!({:mobs, %{appear: a, lists: l, gone: g, about: ab, npc?: f}, _m, _r}, _packets)
       when is_list(a) and is_list(l) and is_list(g) and is_list(ab) and is_function(f, 2) do
    Masks.validate!(for({mod, handle, id} <- a, p <- [handle, id], do: {mod, p, "x"}))
    Masks.validate!(for {mod, handle} <- g ++ ab, do: {mod, handle, "x"})

    Enum.each(l, fn {mod, array, handle, id, max} ->
      if not (is_integer(max) and max > 0), do: raise(ArgumentError, "deferral :mobs list max must be above 0")
      Masks.validate!([{mod, array, "x"}])
      {^array, _off, _size, {:array, elem, _count_bytes}} = List.keyfind(mod.__packet__().layout, array, 0)
      Masks.validate!([{elem, handle, "x"}, {elem, id, "x"}])
    end)
  end

  defp check_shape!(entry, _packets), do: raise(ArgumentError, "malformed deferral #{inspect(entry)}")

  @doc """
  Takes the deferred packets out of the transcript packets and adds `:scope` (the map name of the connection, `nil`
  before the first one; `map_names` are `{module, path}` of the server packets that carry it). Indices are untouched.
  """
  @spec apply([Replay.Transcript.packet()], [entry()], [{module(), Masks.path()}]) :: [map()]
  def apply(packets, entries, map_names) do
    unsent = for {:unsent, c, answers, _, _} <- entries, i <- [c | answers], into: MapSet.new(), do: i
    absent_at = for {:absent, indices, _, _} when is_list(indices) <- entries, i <- indices, into: unsent, do: i
    absent = for {:absent, mod, _, _} when is_atom(mod) <- entries, into: MapSet.new(), do: mod.opcode()
    mobs = for {:mobs, m, _, _} <- entries, do: m
    names = for {mod, path} <- map_names, do: {mod.opcode(), mod, path}
    ctx = %{unsent: absent_at, absent: absent, mobs: mobs, names: names}

    {kept, _state} =
      Enum.reduce(packets, {[], %{scope: %{}, excluded: %{}}}, fn packet, {kept, state} ->
        case one(packet, ctx, state) do
          {nil, state} -> {kept, state}
          {packet, state} -> {[packet | kept], state}
        end
      end)

    kept |> Enum.reverse() |> repack(for(m <- mobs, l <- m.lists, do: l))
  end

  # Runs of consecutive list packets of one connection are cut again into lists of at most max elements.
  defp repack(packets, []), do: packets

  defp repack(packets, lists) do
    list = fn p -> if p.dir == :server, do: find(lists, p.opcode) end

    packets
    |> Enum.chunk_by(&if(list.(&1), do: {&1.conn, &1.opcode}, else: {:single, &1.index}))
    |> Enum.flat_map(fn [first | _] = run ->
      case list.(first) do
        {mod, array, _handle, _id, max} -> repack_run(run, mod, array, max)
        nil -> run
      end
    end)
  end

  defp repack_run(run, mod, array, max) do
    {^array, off, nil, {:array, elem, count_bytes}} = List.keyfind(mod.__packet__().layout, array, 0)
    size = elem.__packet__().size
    bits = count_bytes * 8

    elements =
      for p <- run,
          <<_prefix::binary-size(^off), _count::binary-size(^count_bytes), rest::binary>> = p.payload,
          <<e::binary-size(^size) <- rest>>,
          do: e

    for {p, chunk} <- Enum.zip(run, Enum.chunk_every(elements, max)) do
      <<prefix::binary-size(^off), _rest::binary>> = p.payload
      %{p | payload: prefix <> <<length(chunk)::little-size(bits)>> <> Enum.join(chunk)}
    end
  end

  defp one(packet, ctx, state) do
    cond do
      packet.index in ctx.unsent -> {nil, state}
      packet.dir == :server and packet.opcode in ctx.absent -> {nil, state}
      true -> packet |> with_scope(ctx, state) |> mobs(ctx.mobs)
    end
  end

  defp with_scope(%{dir: :server} = packet, ctx, state) do
    case Enum.find(ctx.names, &(elem(&1, 0) == packet.opcode)) do
      {_op, mod, path} ->
        [{off, size}] = Masks.ranges(mod, path, packet.payload)
        name = packet.payload |> binary_part(off, size) |> String.trim_trailing(<<0>>)
        state = %{state | scope: Map.put(state.scope, packet.conn, name)}
        {scoped(packet, state), put_in(state.excluded[packet.conn], MapSet.new())}

      nil ->
        {scoped(packet, state), state}
    end
  end

  defp with_scope(packet, _ctx, state), do: {scoped(packet, state), state}

  defp scoped(packet, state), do: Map.put(packet, :scope, Map.get(state.scope, packet.conn))

  defp mobs({packet, state}, entries) do
    conn = packet.conn
    excluded = Map.get(state.excluded, conn, MapSet.new())

    {packet, excluded} =
      for m <- entries, step <- [&appear/3, &list/3, &gone/3, &about/3], reduce: {packet, excluded} do
        acc -> mob_step(step, acc, m)
      end

    {packet, put_in(state.excluded[conn], excluded)}
  end

  # a packet taken out stays out
  defp mob_step(_fun, {nil, excluded}, _m), do: {nil, excluded}
  defp mob_step(fun, {packet, excluded}, m), do: fun.(packet, m, excluded)

  defp find(entries, opcode), do: Enum.find(entries, &(elem(&1, 0).opcode() == opcode))

  defp bytes(mod, path, payload) do
    for {off, size} <- Masks.ranges(mod, path, payload), do: binary_part(payload, off, size)
  end

  defp appear(%{dir: :server} = packet, m, excluded) do
    case find(m.appear, packet.opcode) do
      {mod, handle, id} ->
        [mob_id] = bytes(mod, id, packet.payload)

        if m.npc?.(packet.scope, :binary.decode_unsigned(mob_id, :little)),
          do: {packet, excluded},
          else: {nil, MapSet.union(excluded, MapSet.new(bytes(mod, handle, packet.payload)))}

      nil ->
        {packet, excluded}
    end
  end

  defp appear(packet, _m, excluded), do: {packet, excluded}

  defp list(%{dir: :server} = packet, m, excluded) do
    case find(m.lists, packet.opcode) do
      {mod, array, handle, id, _max} -> reduce_list(packet, mod, {array, handle, id}, m, excluded)
      nil -> {packet, excluded}
    end
  end

  defp list(packet, _m, excluded), do: {packet, excluded}

  defp reduce_list(packet, mod, {array, handle, id}, m, excluded) do
    {^array, off, nil, {:array, elem, count_bytes}} = List.keyfind(mod.__packet__().layout, array, 0)
    size = elem.__packet__().size
    <<prefix::binary-size(^off), _count::binary-size(^count_bytes), rest::binary>> = packet.payload
    elements = for <<e::binary-size(^size) <- rest>>, do: e

    {keep, drop} =
      Enum.split_with(elements, fn e ->
        [id_bytes] = bytes(elem, id, e)
        m.npc?.(packet.scope, :binary.decode_unsigned(id_bytes, :little))
      end)

    excluded = Enum.reduce(drop, excluded, fn e, acc -> MapSet.union(acc, MapSet.new(bytes(elem, handle, e))) end)
    count = length(keep)
    bits = count_bytes * 8

    case keep do
      [] -> {nil, excluded}
      _ -> {%{packet | payload: prefix <> <<count::little-size(bits)>> <> Enum.join(keep)}, excluded}
    end
  end

  defp gone(%{dir: :server} = packet, m, excluded) do
    with {mod, handle} <- find(m.gone, packet.opcode),
         [value] = bytes(mod, handle, packet.payload),
         true <- MapSet.member?(excluded, value) do
      {nil, MapSet.delete(excluded, value)}
    else
      _ -> {packet, excluded}
    end
  end

  defp gone(packet, _m, excluded), do: {packet, excluded}

  defp about(packet, m, excluded) do
    with {mod, path} <- find(m.about, packet.opcode),
         true <- Enum.any?(bytes(mod, path, packet.payload), &MapSet.member?(excluded, &1)) do
      {nil, excluded}
    else
      _ -> {packet, excluded}
    end
  end
end
