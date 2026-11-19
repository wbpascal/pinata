defmodule Replay.Failure do
  @moduledoc "Why a replay failed; `message` is the full text to print."

  @enforce_keys [:kind, :conn, :index, :opcode, :message]
  defstruct [:kind, :conn, :index, :opcode, :message]

  @type t :: %__MODULE__{
          kind: :mismatch | :unexpected | :missing | :extra | :handle,
          conn: String.t(),
          index: non_neg_integer(),
          opcode: 0..0xFFFF,
          message: String.t()
        }
end

defmodule Replay do
  @moduledoc """
  The replay harness (ADR 0008, `docs/technical/testing.md`): plays a transcript against listeners and compares
  the server packets byte for byte per connection.

  Options: `stop:` (required, a packet index or `:end`), `endpoints:` (required, connection kind to `{host, port}`),
  `masks:` and `handles:` (per-test additions to `Replay.Masks`), `close_after:` (packet indices; the harness closes
  the connection of that packet right after it, as the client did; the transcript holds no TCP close), `sync_after:`
  (packet indices; a heartbeat round trip after each, so the server has handled the packet before the clock moves
  on), `timeout:` (ms to wait for a packet, 2000).

  The test clock is set on every node of the topology (`Replay.Topology.all/3`).
  """

  alias Replay.Failure
  alias Replay.Masks
  alias Replay.Transcript

  # ADR 0008: heartbeat (0x0804) and game time (0x080E) are sent by timers, not by the replayed actions.
  @timer_driven [0x0804, 0x080E]

  @opcodes_path Path.expand("../../../docs/protocol/opcodes.json", __DIR__)

  @doc "Replays a transcript; the first failure is returned."
  @spec run(Transcript.t(), keyword()) :: :ok | {:error, Failure.t()}
  def run(%Transcript{} = transcript, opts) do
    opts =
      Keyword.validate!(opts, [
        :stop,
        :endpoints,
        masks: [],
        handles: [],
        close_after: [],
        sync_after: [],
        timeout: 2000
      ])

    masks = Masks.global() ++ port_masks(opts[:endpoints]) ++ opts[:masks]
    handles = Masks.handles() ++ opts[:handles]
    :ok = Masks.validate!(masks)
    :ok = Masks.validate!(handles)

    stop = Keyword.fetch!(opts, :stop)
    packets = Enum.filter(transcript.packets, &(stop == :end or &1.index <= stop))

    ctx = %{
      capture: transcript.capture,
      endpoints: Keyword.fetch!(opts, :endpoints),
      masks: masks,
      handles: handles,
      close_after: opts[:close_after],
      sync_after: opts[:sync_after],
      timeout: opts[:timeout]
    }

    previous = Application.fetch_env(:pinata, :clock_source)
    Replay.Topology.all(Application, :put_env, [:pinata, :clock_source, TestClock])
    state = %{clients: %{}, order: [], bound: %{}, last: %{}}

    try do
      with {:ok, state} <- walk(packets, state, ctx), do: drain_all(state, ctx)
    after
      case previous do
        {:ok, source} -> Replay.Topology.all(Application, :put_env, [:pinata, :clock_source, source])
        :error -> Replay.Topology.all(Application, :delete_env, [:pinata, :clock_source])
      end
    end
  end

  # The captures hold the default WorldManager port; a topology on other ports (multi) cannot reproduce it.
  defp port_masks(%{"wm" => {_host, 9110}}), do: []

  defp port_masks(_endpoints),
    do: [
      {Proto.Packets.UserWorldselectAck, :port,
       "the WorldManager of this topology listens on another port than the capture's"}
    ]

  @doc "Like `run/2`; fails the test with the failure message."
  @spec assert_replay(Transcript.t(), keyword()) :: :ok
  def assert_replay(transcript, opts) do
    case run(transcript, opts) do
      :ok -> :ok
      {:error, failure} -> ExUnit.Assertions.flunk(failure.message)
    end
  end

  # -- walking the packets

  defp walk([], state, _ctx), do: {:ok, state}

  defp walk([packet | rest], state, ctx) do
    state = open(packet, state, ctx)
    state = %{state | last: Map.put(state.last, packet.conn, packet.index)}

    case step(packet, state, ctx) do
      {:ok, state} ->
        case sync_if_due(state, packet, ctx) do
          {:ok, state} -> walk(rest, close_if_due(state, packet, ctx), ctx)
          {:error, _failure} = error -> close_all(state, error)
        end

      {:error, _failure} = error ->
        close_all(state, error)
    end
  end

  # A heartbeat round trip: the server has handled the packet before the clock moves on. Needed where the server
  # sends nothing and the replay leaves out the answer of a later issue.
  defp sync_if_due(state, packet, ctx) do
    with true <- packet.index in ctx.sync_after,
         {:ok, client} <- TestClient.send_raw(Map.fetch!(state.clients, packet.conn), <<0x04, 0x08>>),
         {:ok, client} <- sync_ack(client, packet, ctx) do
      {:ok, put_client(state, packet.conn, client)}
    else
      false -> {:ok, state}
      {:error, :closed} -> {:error, failure(:missing, ctx, packet, "the server closed the connection", [])}
      {:error, _failure} = error -> error
    end
  end

  defp sync_ack(client, packet, ctx) do
    case next_body(client, ctx.timeout) do
      {:ok, <<0x05, 0x08>>, client} ->
        {:ok, client}

      {:ok, <<opcode::little-16, payload::binary>>, _client} ->
        lines = ["extra packet: #{opcode_text(opcode)}", "payload: #{hex(payload)}"]
        {:error, failure(:extra, ctx, %{packet | opcode: opcode}, "extra packet", lines)}

      {:error, _reason, _client} ->
        {:error, failure(:missing, ctx, packet, "no answer to the heartbeat", [])}
    end
  end

  # The client closed this connection after the packet; the transcript holds no TCP close.
  defp close_if_due(state, packet, ctx) do
    if packet.index in ctx.close_after do
      TestClient.close(Map.fetch!(state.clients, packet.conn))
      %{state | clients: Map.delete(state.clients, packet.conn), order: List.delete(state.order, packet.conn)}
    else
      state
    end
  end

  defp open(%{conn: conn} = packet, state, ctx) do
    if Map.has_key?(state.clients, conn) do
      state
    else
      Replay.Topology.all(TestClock, :set, [packet.time])
      [kind | _] = String.split(conn, "#")
      {host, port} = Map.fetch!(ctx.endpoints, kind)
      client = TestClient.connect(host, port)
      %{state | clients: Map.put(state.clients, conn, client), order: state.order ++ [conn]}
    end
  end

  defp step(%{dir: :server, opcode: opcode}, state, _ctx) when opcode in @timer_driven, do: {:ok, state}

  defp step(%{dir: :server} = packet, state, ctx) do
    case next_body(Map.fetch!(state.clients, packet.conn), ctx.timeout) do
      {:error, reason, _client} ->
        what =
          if reason == :timeout, do: "packet missing (timed out)", else: "packet missing (server closed the connection)"

        {:error, failure(:missing, ctx, packet, what, [])}

      {:ok, <<opcode::little-16, received::binary>>, client} when opcode == packet.opcode ->
        state = put_client(state, packet.conn, client)

        case compare(packet, received, state.bound, ctx) do
          {:ok, bound} -> {:ok, %{state | bound: bound}}
          {:error, _failure} = error -> error
        end

      {:ok, <<opcode::little-16, received::binary>>, _client} ->
        lines = [
          "expected: #{opcode_text(packet.opcode)}",
          "received: #{opcode_text(opcode)}",
          "payload: #{hex(received)}"
        ]

        {:error, failure(:unexpected, ctx, packet, "unexpected packet", lines)}
    end
  end

  defp step(%{dir: :client} = packet, state, ctx) do
    Replay.Topology.all(TestClock, :set, [packet.time])

    with {:ok, payload} <- rewrite(packet, state.bound, ctx),
         {:ok, client} <-
           send_or_missing(Map.fetch!(state.clients, packet.conn), packet, payload, ctx) do
      {:ok, put_client(state, packet.conn, client)}
    end
  end

  defp send_or_missing(client, packet, payload, ctx) do
    case TestClient.send_raw(client, <<packet.opcode::little-16, payload::binary>>) do
      {:ok, client} -> {:ok, client}
      {:error, :closed} -> {:error, failure(:missing, ctx, packet, "the server closed the connection", [])}
    end
  end

  defp put_client(state, conn, client), do: %{state | clients: Map.put(state.clients, conn, client)}

  # next body of the connection, timer-driven packets dropped
  defp next_body(client, timeout) do
    case TestClient.recv_raw(client, timeout) do
      {:ok, <<opcode::little-16, _::binary>>, client} when opcode in @timer_driven -> next_body(client, timeout)
      {:ok, body, client} -> {:ok, body, client}
      {:error, reason} -> {:error, reason, client}
    end
  end

  # -- end of the replay: a heartbeat on each connection finds extra packets

  defp drain_all(state, ctx) do
    result =
      Enum.reduce_while(state.order, :ok, fn conn, :ok ->
        client = Map.fetch!(state.clients, conn)
        packet = %{conn: conn, index: Map.fetch!(state.last, conn), opcode: 0x0804}

        case drain(client, packet, ctx) do
          :ok -> {:cont, :ok}
          {:error, _failure} = error -> {:halt, error}
        end
      end)

    close_all(state, result)
  end

  defp drain(%TestClient{cipher: nil}, _packet, _ctx), do: :ok

  defp drain(client, packet, ctx) do
    case TestClient.send_raw(client, <<0x04, 0x08>>) do
      {:error, :closed} -> :ok
      {:ok, client} -> read_until_ack(client, packet, ctx)
    end
  end

  defp read_until_ack(client, packet, ctx) do
    case TestClient.recv_raw(client, ctx.timeout) do
      {:ok, <<0x05, 0x08>>, _client} ->
        :ok

      {:ok, <<opcode::little-16, _::binary>>, client} when opcode in @timer_driven ->
        read_until_ack(client, packet, ctx)

      {:ok, <<opcode::little-16, payload::binary>>, _client} ->
        lines = ["extra packet: #{opcode_text(opcode)}", "payload: #{hex(payload)}"]
        {:error, failure(:extra, ctx, %{packet | opcode: opcode}, "extra packet", lines)}

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        {:error, failure(:missing, ctx, packet, "no answer to the end-of-replay heartbeat", [])}
    end
  end

  defp close_all(state, result) do
    Enum.each(state.clients, fn {_conn, client} -> TestClient.close(client) end)
    result
  end

  # -- comparing

  defp compare(packet, received, bound, ctx) do
    expected = packet.payload
    entries = for e <- ctx.masks ++ ctx.handles, elem(e, 0).opcode() == packet.opcode, do: e
    mods = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    handles = for {mod, path, ns, _} <- ctx.handles, mod in mods, do: {mod, path, ns}
    masks = for {mod, path, _} <- ctx.masks, mod in mods, do: {mod, path}

    if byte_size(expected) == byte_size(received) do
      compare_same_size(packet, received, {masks, handles, mods}, bound, ctx)
    else
      lines = [
        "size: expected #{byte_size(expected)}, got #{byte_size(received)}",
        "expected: #{hex(expected)}",
        "got: #{hex(received)}"
      ]

      {:error, failure(:mismatch, ctx, packet, "byte mismatch", lines)}
    end
  end

  defp compare_same_size(packet, received, {masks, handles, mods}, bound, ctx) do
    with {:ok, bound} <- bind(handles, packet, received, bound, ctx) do
      zeroed = masks ++ for({mod, path, _ns} <- handles, do: {mod, path})
      compare_zeroed(packet, zero(packet.payload, zeroed), zero(received, zeroed), mods, bound, ctx)
    end
  end

  defp compare_zeroed(_packet, same, same, _mods, bound, _ctx), do: {:ok, bound}

  defp compare_zeroed(packet, expected, received, mods, _bound, ctx) do
    lines = diff(mods_or_registry(mods, packet.opcode), expected, received)
    {:error, failure(:mismatch, ctx, packet, "byte mismatch", lines)}
  end

  defp mods_or_registry([mod | _], _opcode), do: {:ok, mod}
  defp mods_or_registry([], opcode), do: Proto.Packets.fetch(opcode)

  defp zero(payload, entries) do
    for {mod, path} <- entries, reduce: payload do
      acc ->
        for {off, size} <- Masks.ranges(mod, path, acc), reduce: acc do
          acc -> replace(acc, off, size, :binary.copy(<<0>>, size))
        end
    end
  end

  defp replace(bin, off, size, new) do
    <<pre::binary-size(^off), _::binary-size(^size), post::binary>> = bin
    pre <> new <> post
  end

  defp slice(bin, off, size) do
    off = min(off, byte_size(bin))
    binary_part(bin, off, min(size || byte_size(bin), byte_size(bin) - off))
  end

  defp diff({:ok, mod}, expected, received) do
    lines =
      for {name, off, size, _sub} <- Enum.uniq_by(mod.__packet__().layout, &elem(&1, 1)),
          slice(expected, off, size) != slice(received, off, size) do
        "  #{name}: expected #{hex(slice(expected, off, size))}, got #{hex(slice(received, off, size))}"
      end

    if lines == [], do: diff(:error, expected, received), else: lines
  end

  defp diff(:error, expected, received), do: ["  payload: expected #{hex(expected)}, got #{hex(received)}"]

  # -- handles

  defp bind(handles, packet, received, bound, ctx) do
    ranges =
      for {mod, path, ns} <- handles,
          {off, size} <- Masks.ranges(mod, path, packet.payload),
          do: {path, ns, off, size}

    Enum.reduce_while(ranges, {:ok, bound}, fn {path, ns, off, size}, {:ok, bound} ->
      case bind_one(bound, ns, slice(packet.payload, off, size), slice(received, off, size)) do
        {:ok, bound} ->
          {:cont, {:ok, bound}}

        {:error, text} ->
          {:halt, {:error, failure(:handle, ctx, packet, "handle mismatch", ["  #{path_text(path)}: #{text}"])}}
      end
    end)
  end

  defp bind_one(bound, ns, orig, new) do
    map = Map.get(bound, ns, %{})

    case Map.fetch(map, orig) do
      {:ok, ^new} -> {:ok, bound}
      {:ok, other} -> {:error, "original #{hex(orig)} is bound to #{hex(other)}, got #{hex(new)}"}
      :error -> bind_new(bound, ns, map, orig, new)
    end
  end

  defp bind_new(bound, ns, map, orig, new) do
    case Enum.find(map, fn {_o, n} -> n == new end) do
      nil -> {:ok, Map.put(bound, ns, Map.put(map, orig, new))}
      {o, _} -> {:error, "received #{hex(new)} is already bound to original #{hex(o)}, not #{hex(orig)}"}
    end
  end

  # replaces the captured handle values of a client packet by the ones of this run
  defp rewrite(packet, bound, ctx) do
    ranges =
      for {mod, path, ns, _} <- ctx.handles,
          mod.opcode() == packet.opcode,
          {off, size} <- Masks.ranges(mod, path, packet.payload),
          do: {path, ns, off, size}

    Enum.reduce_while(ranges, {:ok, packet.payload}, fn {path, ns, off, size}, {:ok, payload} ->
      orig = slice(payload, off, size)

      case bound |> Map.get(ns, %{}) |> Map.fetch(orig) do
        {:ok, new} ->
          {:cont, {:ok, replace(payload, off, size, new)}}

        :error ->
          text = "  #{path_text(path)}: the client uses #{hex(orig)}, an identifier the server never sent"
          {:halt, {:error, failure(:handle, ctx, packet, "handle mismatch", [text])}}
      end
    end)
  end

  defp path_text(path), do: path |> List.wrap() |> Enum.join(".")

  # -- messages

  defp failure(kind, ctx, packet, what, lines) do
    message =
      Enum.join(
        [
          "replay of #{ctx.capture} failed: #{what}",
          "connection: #{packet.conn}",
          "packet index: #{packet.index}",
          "opcode: #{opcode_text(packet.opcode)}" | lines
        ],
        "\n"
      )

    %Failure{kind: kind, conn: packet.conn, index: packet.index, opcode: packet.opcode, message: message}
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp opcode_text(opcode), do: "#{opcode_hex(opcode)} #{opcode_name(opcode_hex(opcode))}"

  defp opcode_hex(opcode), do: "0x" <> (opcode |> Integer.to_string(16) |> String.pad_leading(4, "0"))

  defp opcode_name(hex) do
    with {:ok, text} <- File.read(@opcodes_path),
         %{"name" => name} when is_binary(name) <- text |> JSON.decode!() |> Enum.find(&(&1["op"] == hex)) do
      name
    else
      _ -> "unknown"
    end
  end
end
