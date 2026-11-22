defmodule Net.Connection do
  @moduledoc """
  One process per client socket. It sends the seed, cuts frames, decrypts and decodes them, answers heartbeats,
  hands every other packet to the part handler and carries out the effects it returns (send, perform, log, close). A
  packet of the wrong size is dropped. It closes the socket, without an error packet, on an unknown opcode, on
  oversized frames and when a limit is exceeded. It knows its part (the label of the server log) and the peer address:
  every line it writes carries both, and both are Logger metadata (`part`, `peer`) of the process. Every close it
  decides on writes one line with the reason; a close by the client writes one `debug` line. The handling of each
  decoded packet is the telemetry span `[:pinata, :packet]` (`docs/technical/telemetry.md`).
  See `docs/technical/processes.md`.
  """

  use ThousandIsland.Handler

  require Logger

  alias Proto.Packets.MiscHeartbeatAck
  alias Proto.Packets.MiscHeartbeatReq
  alias Proto.Packets.MiscSeedAck

  @check_ms 1_000
  @ping_after_ms 30_000
  @close_after_ms 210_000
  @max_body 0x1FFD

  @enforce_keys [:handler, :handler_state, :limits, :cipher, :last_packet, :window_start, :part, :peer]
  defstruct [:handler, :handler_state, :limits, :cipher, :last_packet, :window_start, :part, :peer] ++
              [buffer: <<>>, pinged?: false, window_count: 0, closed?: false]

  @type t :: %__MODULE__{
          handler: module(),
          handler_state: term(),
          limits: %{max_packets_per_second: pos_integer(), max_unsent_bytes: pos_integer()},
          cipher: Proto.Cipher.t(),
          last_packet: integer(),
          window_start: integer(),
          buffer: binary(),
          pinged?: boolean(),
          window_count: non_neg_integer(),
          part: String.t(),
          peer: String.t(),
          closed?: boolean()
        }

  @impl ThousandIsland.Handler
  def handle_connection(socket, %{handler: handler, limits: limits, settings: settings, part: part}) do
    {:ok, {address, port}} = ThousandIsland.Socket.peername(socket)
    peer = "#{:inet.ntoa(address)}:#{port}"
    Logger.metadata(part: part, peer: peer)
    Logger.debug("#{part}: connection accepted, peer #{peer}")
    seed = Random.uniform(499) - 1
    now = Clock.monotonic_time(:millisecond)

    state = %__MODULE__{
      handler: handler,
      handler_state: handler.init(settings),
      limits: limits,
      cipher: Proto.Cipher.new(seed),
      last_packet: now,
      window_start: now,
      part: part,
      peer: peer
    }

    _ = Process.send_after(self(), :check, @check_ms)
    send_packets(socket, [%MiscSeedAck{seed: seed}], state)
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state), do: frames(socket, %{state | buffer: state.buffer <> data})

  @impl ThousandIsland.Handler
  def handle_close(_socket, %__MODULE__{closed?: false} = state),
    do: log(state, :debug, "connection closed by the client")

  def handle_close(_socket, _state), do: :ok

  @impl GenServer
  def handle_info(:check, {socket, state}) do
    _ = Process.send_after(self(), :check, @check_ms)
    idle = Clock.monotonic_time(:millisecond) - state.last_packet

    cond do
      idle >= @close_after_ms ->
        close(state, :info, "heartbeat timeout") |> reply(socket)

      idle >= @ping_after_ms and not state.pinged? ->
        send_packets(socket, [%MiscHeartbeatReq{}], %{state | pinged?: true}) |> reply(socket)

      true ->
        {:noreply, {socket, state}}
    end
  end

  def handle_info({:cluster, _} = message, {socket, state}) do
    {handler_state, effects} = state.handler.handle_info(state.handler_state, message)
    effects(socket, effects, %{state | handler_state: handler_state}) |> reply(socket)
  end

  defp reply({:continue, state}, socket), do: {:noreply, {socket, state}}
  defp reply({:close, state}, socket), do: {:stop, {:shutdown, :local_closed}, {socket, state}}

  defp log(state, level, message), do: Logger.log(level, "#{state.part}: #{message}, peer #{state.peer}")

  defp close(state, level, reason) do
    log(state, level, "connection closed: " <> reason)
    {:close, %{state | closed?: true}}
  end

  defp frames(_socket, %{buffer: <<0, len::little-16, _::binary>>} = state) when len > @max_body,
    do: close(state, :info, "oversized frame")

  defp frames(socket, state) do
    case Proto.Framing.split(state.buffer) do
      :more -> {:continue, state}
      {:ok, body, rest} -> frame(socket, body, count(%{state | buffer: rest}))
    end
  end

  defp frame(socket, body, state) do
    if state.window_count > state.limits.max_packets_per_second do
      close(state, :warning, "packet rate exceeded")
    else
      {plain, cipher} = Proto.Cipher.crypt(state.cipher, body)
      state = %{state | cipher: cipher}

      case Proto.decode(plain) do
        # As the original: all three servers disconnect a client that sends an unregistered opcode.
        {:error, :unknown_opcode} ->
          <<opcode::little-16, _::binary>> = plain
          close(state, :info, "unknown opcode 0x" <> Integer.to_string(opcode, 16))

        # As the original's length checks (0x0C5A, 0x0C37): the packet is dropped, the connection goes on.
        # It counted for the packet rate and does not count as a sign of life for the heartbeat.
        {:error, :bad_size} ->
          log(
            state,
            :debug,
            "dropped a packet of the wrong size (#{inspect(binary_part(plain, 0, min(2, byte_size(plain))))}, #{byte_size(plain)} bytes)"
          )

          frames(socket, state)

        {:ok, packet} ->
          handle(socket, packet, %{state | last_packet: Clock.monotonic_time(:millisecond), pinged?: false})
      end
    end
  end

  # The packet handling time (docs/technical/telemetry.md): from the decoded packet to its effects handed to the socket.
  defp handle(socket, %module{} = packet, state) do
    metadata = %{part: state.part, opcode: module |> Module.split() |> List.last()}

    case :telemetry.span([:pinata, :packet], metadata, fn -> {packet(socket, packet, state), metadata} end) do
      {:continue, state} -> frames(socket, state)
      {:close, state} -> {:close, state}
    end
  end

  defp count(state) do
    now = Clock.monotonic_time(:millisecond)

    if now - state.window_start >= 1000,
      do: %{state | window_start: now, window_count: 1},
      else: %{state | window_count: state.window_count + 1}
  end

  defp packet(socket, %MiscHeartbeatReq{}, state), do: send_packets(socket, [%MiscHeartbeatAck{}], state)
  defp packet(_socket, %MiscHeartbeatAck{}, state), do: {:continue, state}

  defp packet(socket, packet, state) do
    {handler_state, effects} = state.handler.handle_packet(state.handler_state, packet)
    effects(socket, effects, %{state | handler_state: handler_state})
  end

  defp effects(_socket, [], state), do: {:continue, state}
  defp effects(_socket, [{:close, level, reason} | _], state), do: close(state, level, reason)

  defp effects(socket, [{:log, level, message} | rest], state) do
    log(state, level, message)
    effects(socket, rest, state)
  end

  defp effects(socket, [{:send, packet} | rest], state) do
    case send_packets(socket, [packet], state) do
      {:continue, state} -> effects(socket, rest, state)
      {:close, state} -> {:close, state}
    end
  end

  defp effects(socket, [{:perform, request} | rest], state) do
    message = state.handler.perform(request)
    {handler_state, more} = state.handler.handle_info(state.handler_state, message)
    effects(socket, more ++ rest, %{state | handler_state: handler_state})
  end

  defp send_packets(socket, packets, state) do
    Enum.reduce_while(packets, {:continue, state}, fn packet, acc ->
      {:ok, frame} = Proto.Framing.frame(Proto.encode(packet))

      case send_frame(socket, frame, state) do
        :ok -> {:cont, acc}
        {:close, level, reason} -> {:halt, close(state, level, reason)}
      end
    end)
  end

  defp send_frame(socket, frame, state) do
    with :ok <- ThousandIsland.Socket.send(socket, frame),
         {:ok, stats} <- ThousandIsland.Socket.getstat(socket) do
      if Keyword.fetch!(stats, :send_pend) <= state.limits.max_unsent_bytes,
        do: :ok,
        else: {:close, :warning, "unsent bytes exceeded"}
    else
      {:error, _} -> {:close, :warning, "send failed"}
    end
  end
end
