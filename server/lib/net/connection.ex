defmodule Net.Connection do
  @moduledoc """
  One process per client socket. It sends the seed, cuts frames, decrypts and decodes them, answers heartbeats,
  hands every other packet to the part handler and sends what the handler returns. It closes the socket, without
  an error packet, on garbage, oversized frames and when a limit is exceeded.
  See `docs/technical/processes.md`.
  """

  use ThousandIsland.Handler

  alias Proto.Packets.MiscHeartbeatAck
  alias Proto.Packets.MiscHeartbeatReq
  alias Proto.Packets.MiscSeedAck

  @check_ms 1_000
  @ping_after_ms 30_000
  @close_after_ms 210_000
  @max_body 0x1FFD

  @enforce_keys [:handler, :handler_state, :limits, :cipher, :last_packet, :window_start]
  defstruct [:handler, :handler_state, :limits, :cipher, :last_packet, :window_start] ++
              [buffer: <<>>, pinged?: false, window_count: 0]

  @type t :: %__MODULE__{
          handler: module(),
          handler_state: term(),
          limits: %{max_packets_per_second: pos_integer(), max_unsent_bytes: pos_integer()},
          cipher: Proto.Cipher.t(),
          last_packet: integer(),
          window_start: integer(),
          buffer: binary(),
          pinged?: boolean(),
          window_count: non_neg_integer()
        }

  @impl ThousandIsland.Handler
  def handle_connection(socket, %{handler: handler, limits: limits}) do
    seed = Random.uniform(499) - 1
    now = Clock.monotonic_time(:millisecond)

    state = %__MODULE__{
      handler: handler,
      handler_state: handler.init(),
      limits: limits,
      cipher: Proto.Cipher.new(seed),
      last_packet: now,
      window_start: now
    }

    _ = Process.send_after(self(), :check, @check_ms)
    send_packets(socket, [%MiscSeedAck{seed: seed}], state)
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state), do: frames(socket, %{state | buffer: state.buffer <> data})

  @impl GenServer
  def handle_info(:check, {socket, state}) do
    _ = Process.send_after(self(), :check, @check_ms)
    idle = Clock.monotonic_time(:millisecond) - state.last_packet

    cond do
      idle >= @close_after_ms ->
        {:stop, {:shutdown, :local_closed}, {socket, state}}

      idle >= @ping_after_ms and not state.pinged? ->
        send_packets(socket, [%MiscHeartbeatReq{}], %{state | pinged?: true}) |> reply(socket)

      true ->
        {:noreply, {socket, state}}
    end
  end

  defp reply({:continue, state}, socket), do: {:noreply, {socket, state}}
  defp reply({:close, state}, socket), do: {:stop, {:shutdown, :local_closed}, {socket, state}}

  defp frames(_socket, %{buffer: <<0, len::little-16, _::binary>>} = state) when len > @max_body, do: {:close, state}

  defp frames(socket, state) do
    case Proto.Framing.split(state.buffer) do
      :more -> {:continue, state}
      {:ok, body, rest} -> frame(socket, body, count(%{state | buffer: rest}))
    end
  end

  defp frame(socket, body, state) do
    if state.window_count > state.limits.max_packets_per_second do
      {:close, state}
    else
      {plain, cipher} = Proto.Cipher.crypt(state.cipher, body)
      state = %{state | cipher: cipher}

      case Proto.decode(plain) do
        {:error, _reason} ->
          {:close, state}

        {:ok, packet} ->
          handle(socket, packet, %{state | last_packet: Clock.monotonic_time(:millisecond), pinged?: false})
      end
    end
  end

  defp handle(socket, packet, state) do
    case packet(socket, packet, state) do
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
    send_packets(socket, Enum.map(effects, fn {:send, p} -> p end), %{state | handler_state: handler_state})
  end

  defp send_packets(socket, packets, state) do
    Enum.reduce_while(packets, {:continue, state}, fn packet, acc ->
      {:ok, frame} = Proto.Framing.frame(Proto.encode(packet))

      with :ok <- ThousandIsland.Socket.send(socket, frame),
           {:ok, stats} <- ThousandIsland.Socket.getstat(socket),
           true <- Keyword.fetch!(stats, :send_pend) <= state.limits.max_unsent_bytes do
        {:cont, acc}
      else
        _ -> {:halt, {:close, state}}
      end
    end)
  end
end
