defmodule Net.ConnectionTest do
  # Swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  defmodule FakeClock do
    @moduledoc false
    @behaviour Clock.Source

    @impl Clock.Source
    def system_time(_unit), do: :persistent_term.get({__MODULE__, :now}, 0)
    @impl Clock.Source
    def monotonic_time(_unit), do: :persistent_term.get({__MODULE__, :now}, 0)
  end

  defmodule Big do
    @moduledoc false
    use Proto.Packet, opcode: 0x7FFF

    field :data, {:bytes, 8000}
  end

  defmodule FloodHandler do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init, do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, List.duplicate({:send, %Big{data: :binary.copy(<<0>>, 8000)}}, 4000)}
  end

  defmodule QuietHandler do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init, do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, []}
  end

  @limits %{max_packets_per_second: 100, max_unsent_bytes: 1_048_576}

  setup do
    Application.put_env(:pinata, :clock_source, FakeClock)
    set_now(0)

    on_exit(fn ->
      Application.delete_env(:pinata, :clock_source)
      :persistent_term.erase({FakeClock, :now})
    end)
  end

  defp set_now(ms), do: :persistent_term.put({FakeClock, :now}, ms)

  defp listen(handler, limits \\ %{}) do
    settings = %{connection: Map.merge(@limits, limits)}
    pid = start_supervised!({Net.Listener, {handler, 0, settings}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  defp connect(port, options \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, {:active, false}] ++ options)
    {:ok, <<4, 0x07, 0x08, seed::little-16>>} = :gen_tcp.recv(socket, 5, 1000)
    {socket, Proto.Cipher.new(seed)}
  end

  defp frame(cipher, body) do
    {enc, cipher} = Proto.Cipher.crypt(cipher, body)
    {:ok, frame} = Proto.Framing.frame(enc)
    {frame, cipher}
  end

  defp conn_pid(listener) do
    {:ok, [pid]} = ThousandIsland.connection_pids(listener)
    pid
  end

  defp check(listener, wait? \\ true) do
    pid = conn_pid(listener)
    send(pid, :check)
    if wait?, do: :sys.get_state(pid)
    :ok
  end

  defp nothing(socket), do: assert(:gen_tcp.recv(socket, 0, 0) == {:error, :timeout})
  defp closed(socket), do: assert(:gen_tcp.recv(socket, 0, 1000) == {:error, :closed})

  test "heartbeat answered keeps the connection" do
    {listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)

    set_now(29_999)
    check(listener)
    nothing(socket)
    set_now(30_000)
    check(listener)
    assert {:ok, <<2, 4, 8>>} = :gen_tcp.recv(socket, 3, 1000)
    check(listener)
    nothing(socket)

    {ack, cipher} = frame(cipher, <<0x05, 0x08>>)
    :ok = :gen_tcp.send(socket, ack)
    _ = :sys.get_state(conn_pid(listener))
    set_now(210_000)
    check(listener)
    assert {:ok, <<2, 4, 8>>} = :gen_tcp.recv(socket, 3, 1000)

    {req, _cipher} = frame(cipher, <<0x04, 0x08>>)
    :ok = :gen_tcp.send(socket, req)
    assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
  end

  test "silent socket" do
    {listener, port} = listen(QuietHandler)
    {socket, _cipher} = connect(port)

    set_now(30_000)
    check(listener)
    assert {:ok, <<2, 4, 8>>} = :gen_tcp.recv(socket, 3, 1000)
    set_now(209_999)
    check(listener)
    nothing(socket)
    set_now(210_000)
    check(listener, false)
    closed(socket)
  end

  test "client heartbeat request in the first state" do
    {_listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)
    {req, _cipher} = frame(cipher, <<0x04, 0x08>>)
    :ok = :gen_tcp.send(socket, req)
    assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
  end

  test "garbage closes the socket" do
    {listener, port} = listen(QuietHandler)
    {socket, _cipher} = connect(port)
    :ok = :gen_tcp.send(socket, <<5, 1, 2, 3, 4, 5>>)
    closed(socket)

    {socket, _cipher} = connect(port)
    :ok = :gen_tcp.send(socket, <<1, 0xFF>>)
    closed(socket)

    assert Process.alive?(listener)
    connect(port)
  end

  test "oversized frame closes the socket" do
    {listener, port} = listen(QuietHandler)
    {socket, _cipher} = connect(port)
    :ok = :gen_tcp.send(socket, <<0, 0xFE, 0x1F>>)
    closed(socket)
    assert Process.alive?(listener)

    {socket, _cipher} = connect(port)
    :ok = :gen_tcp.send(socket, <<0, 0xFD, 0x1F>>)
    Process.sleep(100)
    nothing(socket)
  end

  defp heartbeats(cipher, n) do
    {frames, cipher} =
      Enum.map_reduce(1..n, cipher, fn _, cipher -> frame(cipher, <<0x04, 0x08>>) end)

    {IO.iodata_to_binary(frames), cipher}
  end

  test "packet rate" do
    {_listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)
    {data, cipher} = heartbeats(cipher, 100)
    :ok = :gen_tcp.send(socket, data)
    assert {:ok, answers} = :gen_tcp.recv(socket, 300, 2000)
    assert answers == :binary.copy(<<2, 5, 8>>, 100)
    {more, _cipher} = heartbeats(cipher, 1)
    :ok = :gen_tcp.send(socket, more)
    closed(socket)

    {socket, cipher} = connect(port)
    {data, cipher} = heartbeats(cipher, 100)
    :ok = :gen_tcp.send(socket, data)
    assert {:ok, _} = :gen_tcp.recv(socket, 300, 2000)
    set_now(1000)
    {data, _cipher} = heartbeats(cipher, 100)
    :ok = :gen_tcp.send(socket, data)
    assert {:ok, _} = :gen_tcp.recv(socket, 300, 2000)
    Process.sleep(50)
    nothing(socket)
  end

  test "unsent outbound data" do
    {_listener, port} = listen(FloodHandler, %{max_unsent_bytes: 100_000})
    {socket, cipher} = connect(port, recbuf: 8192)
    {req, _cipher} = frame(cipher, <<0x07, 0x08, 0, 0>>)
    :ok = :gen_tcp.send(socket, req)
    Process.sleep(500)
    assert drain(socket, 0) < 4000 * 8003
  end

  defp drain(socket, sum) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, data} -> drain(socket, sum + byte_size(data))
      {:error, :closed} -> sum
    end
  end
end
