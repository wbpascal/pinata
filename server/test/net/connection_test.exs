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
    @impl Clock.Source
    def local_time(_seconds), do: {{2026, 1, 1}, {0, 0, 0}}
    @impl Clock.Source
    def send_after(_pid, _message, _ms), do: :ok
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
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, List.duplicate({:send, %Big{data: :binary.copy(<<0>>, 8000)}}, 4000)}
  end

  defmodule QuietHandler do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, []}
  end

  defmodule EffectHandler do
    @moduledoc false
    @behaviour Net.Handler

    alias Proto.Packets.MiscSeedAck

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet),
      do:
        {state,
         [{:send, %MiscSeedAck{seed: 1}}, {:perform, :ask}, {:close, :info, "test"}, {:send, %MiscSeedAck{seed: 3}}]}

    @impl Net.Handler
    def handle_info(state, :answer), do: {state, [{:send, %MiscSeedAck{seed: 2}}]}
    def handle_info(state, {:cluster, :x}), do: {state, [{:send, %MiscSeedAck{seed: 4}}, {:close, :info, "test"}]}

    @impl Net.Handler
    def perform(:ask), do: :answer
  end

  defmodule CallHandler do
    @moduledoc false
    @behaviour Net.Handler

    alias Proto.Packets.MiscSeedAck

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, []}

    @impl Net.Handler
    def handle_call(state, :q), do: {:answer, state, [{:send, %MiscSeedAck{seed: 5}}]}

    @impl Net.Handler
    def handle_info(state, {:cluster, {:watch, pid}}), do: {state, [{:perform, {:watch, pid}}]}
    def handle_info(state, :watching), do: {state, [{:send, %MiscSeedAck{seed: 7}}]}
    def handle_info(state, {:down, _pid}), do: {state, [{:send, %MiscSeedAck{seed: 6}}]}

    @impl Net.Handler
    def perform({:watch, pid}) do
      _ = Process.monitor(pid)
      :watching
    end
  end

  defmodule SlowHandler do
    @moduledoc false
    @behaviour Net.Handler

    alias Proto.Packets.MiscSeedAck

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, [{:perform, :wait}]}

    @impl Net.Handler
    def handle_info(state, :done), do: {state, List.duplicate({:send, %MiscSeedAck{seed: 1}}, 5)}

    @impl Net.Handler
    # Tells the test that the request was taken, so the client resets the connection only after that.
    def perform(:wait) do
      send(:persistent_term.get({__MODULE__, :test}), :request_taken)
      Process.sleep(100)
      :done
    end
  end

  defmodule LogHandler do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, [{:log, :info, "hello"}, {:perform, :meta}]}

    @impl Net.Handler
    def handle_info(state, _message), do: {state, []}

    @impl Net.Handler
    def perform(:meta) do
      send(:connection_test, {:metadata, Logger.metadata()})
      :ok
    end
  end

  defmodule EndHandler do
    @moduledoc false
    @behaviour Net.Handler

    alias Proto.Packets.MiscSeedAck

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, _packet), do: {state, [{:close, :info, "test"}]}

    @impl Net.Handler
    def handle_info(state, {:timer, :x}), do: {state, [{:send, %MiscSeedAck{seed: 8}}]}

    @impl Net.Handler
    def terminate(_state) do
      # the test may have ended before the connection
      _ = if pid = Process.whereis(:connection_test), do: send(pid, :ended)
      [{:log, :error, "ended"}]
    end
  end

  @limits %{max_packets_per_second: 100, max_unsent_bytes: 1_048_576}

  setup do
    Application.put_env(:pinata, :clock_source, FakeClock)
    set_now(0)

    on_exit(fn ->
      Application.delete_env(:pinata, :clock_source)
      :persistent_term.erase({FakeClock, :now})
      :persistent_term.erase({SlowHandler, :test})
    end)
  end

  defp set_now(ms), do: :persistent_term.put({FakeClock, :now}, ms)

  defp listen(handler, limits \\ %{}, part \\ "Net") do
    settings = %{connection: Map.merge(@limits, limits)}
    pid = start_supervised!({Net.Listener, {part, handler, 0, settings}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  # The line a close writes comes before the socket is closed, so after `closed/1` it is in the capture.
  defp one_close(log, line) do
    assert log =~ line
    assert length(String.split(log, "connection closed:")) == 2
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

  # Waits until the connection has handled what the client sent. Client data reaches the process as a message some
  # time after the send returns, so `:sys.get_state/1` alone is no barrier for it: it only shows an idle process.
  defp await(listener, done?, tries \\ 500) do
    {_socket, state} = :sys.get_state(conn_pid(listener))

    cond do
      done?.(state) ->
        :ok

      tries == 0 ->
        flunk("the connection did not reach the awaited state: #{inspect(state)}")

      true ->
        Process.sleep(10)
        await(listener, done?, tries - 1)
    end
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
    # The acknowledgement must be taken at 30 000: taken after the clock moves on, it would count as fresh.
    await(listener, &(not &1.pinged?))
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

    log =
      TestLog.capture(fn ->
        check(listener, false)
        closed(socket)
      end)

    one_close(log, "[info] Net: connection closed: heartbeat timeout, peer 127.0.0.1:")
  end

  @doc false
  @spec forward([atom()], map(), map(), pid()) :: term()
  def forward(event, measurements, metadata, test), do: send(test, {:telemetry, event, measurements, metadata})

  test "each handled packet is a telemetry span with part and opcode" do
    id = "connection-test-#{inspect(self())}"
    events = [[:pinata, :packet, :start], [:pinata, :packet, :stop]]
    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    {_listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)
    {ack, _cipher} = frame(cipher, <<0x05, 0x08>>)
    :ok = :gen_tcp.send(socket, ack)

    assert_receive {:telemetry, [:pinata, :packet, :start], _, %{part: "Net", opcode: "MiscHeartbeatAck"}}, 1000

    assert_receive {:telemetry, [:pinata, :packet, :stop], %{duration: duration},
                    %{part: "Net", opcode: "MiscHeartbeatAck"}},
                   1000

    assert is_integer(duration) and duration >= 0
  end

  test "client heartbeat request in the first state" do
    {_listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)
    {req, _cipher} = frame(cipher, <<0x04, 0x08>>)
    :ok = :gen_tcp.send(socket, req)
    assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
  end

  test "an unknown opcode closes the socket" do
    {listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)
    {unknown, _cipher} = frame(cipher, <<0xFF, 0xFF, 1, 2, 3>>)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, unknown)
        closed(socket)
      end)

    one_close(log, "[info] Net: connection closed: unknown opcode 0xFFFF, peer 127.0.0.1:")

    assert Process.alive?(listener)
    connect(port)
  end

  test "a known but unbuilt opcode on a Zone connection is dropped with one debug line" do
    {listener, port} = listen(QuietHandler, %{}, "Zone")
    {socket, cipher} = connect(port)
    {unbuilt, cipher} = frame(cipher, <<0x03, 0x20, 0, 0>>)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, unbuilt)
        await(listener, &(&1.window_count == 1))
      end)

    assert log =~ "[debug] Zone: dropped a known but unbuilt packet 0x2003, peer 127.0.0.1:"
    assert length(String.split(log, "dropped a known")) == 2
    refute log =~ "connection closed"
    nothing(socket)

    {req, _cipher} = frame(cipher, <<0x04, 0x08>>)
    :ok = :gen_tcp.send(socket, req)
    assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
  end

  test "a Login connection closes on an opcode another part knows" do
    {_listener, port} = listen(QuietHandler, %{}, "Login")
    {socket, cipher} = connect(port)
    {unbuilt, _cipher} = frame(cipher, <<0x03, 0x20, 0, 0>>)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, unbuilt)
        closed(socket)
      end)

    one_close(log, "[info] Login: connection closed: unknown opcode 0x2003, peer 127.0.0.1:")
  end

  test "a packet of the wrong size is dropped and is no sign of life" do
    {listener, port} = listen(QuietHandler)
    {socket, cipher} = connect(port)

    # a seed packet with one byte too few, then a body shorter than an opcode
    {short, cipher} = frame(cipher, <<0x07, 0x08, 1>>)
    {tiny, cipher} = frame(cipher, <<0x07>>)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, [short, tiny])
        await(listener, &(&1.window_count == 2))
      end)

    assert log =~ "[debug] Net: dropped a packet of the wrong size (\"\\a\\b\", 3 bytes), peer 127.0.0.1:"
    assert log =~ "[debug] Net: dropped a packet of the wrong size (\"\\a\", 1 bytes), peer 127.0.0.1:"
    nothing(socket)

    # the heartbeat timer was not reset by them
    set_now(30_000)
    check(listener)
    assert {:ok, <<2, 4, 8>>} = :gen_tcp.recv(socket, 3, 1000)

    {req, _cipher} = frame(cipher, <<0x04, 0x08>>)
    :ok = :gen_tcp.send(socket, req)
    assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
  end

  test "oversized frame closes the socket" do
    {listener, port} = listen(QuietHandler)
    {socket, _cipher} = connect(port)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, <<0, 0xFE, 0x1F>>)
        closed(socket)
      end)

    one_close(log, "[info] Net: connection closed: oversized frame, peer 127.0.0.1:")
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

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, more)
        closed(socket)
      end)

    one_close(log, "[warning] Net: connection closed: packet rate exceeded, peer 127.0.0.1:")

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

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, req)
        Process.sleep(500)
        assert drain(socket, 0) < 4000 * 8003
      end)

    one_close(log, "[warning] Net: connection closed: unsent bytes exceeded, peer 127.0.0.1:")
  end

  defp drain(socket, sum) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, data} -> drain(socket, sum + byte_size(data))
      {:error, :closed} -> sum
    end
  end

  test "effects run in order and stop at close" do
    {_listener, port} = listen(EffectHandler)
    {socket, cipher} = connect(port)
    {req, _cipher} = frame(cipher, <<0x07, 0x08, 0, 0>>)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, req)
        assert {:ok, <<4, 0x07, 0x08, 1, 0>>} = :gen_tcp.recv(socket, 5, 1000)
        assert {:ok, <<4, 0x07, 0x08, 2, 0>>} = :gen_tcp.recv(socket, 5, 1000)
        closed(socket)
      end)

    one_close(log, "[info] Net: connection closed: test, peer 127.0.0.1:")
  end

  test "a log effect writes a line with part and peer, and the connection has the metadata" do
    Process.register(self(), :connection_test)
    {_listener, port} = listen(LogHandler)
    {socket, cipher} = connect(port)
    {req, _cipher} = frame(cipher, <<0x07, 0x08, 0, 0>>)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, req)
        assert_receive {:metadata, metadata}, 1000
        assert metadata[:part] == "Net"
        assert metadata[:peer] =~ ~r/^127\.0\.0\.1:\d+$/
      end)

    assert log =~ "[info] Net: hello, peer 127.0.0.1:"
  end

  test "a connection is accepted at debug and the listener logs its address" do
    log =
      TestLog.capture(fn ->
        {listener, port} = listen(QuietHandler)
        {:ok, {address, ^port}} = ThousandIsland.listener_info(listener)
        send(self(), {:bound, "#{:inet.ntoa(address)}:#{port}"})
        {socket, _cipher} = connect(port)
        :sys.get_state(conn_pid(listener))
        :gen_tcp.close(socket)
      end)

    assert_received {:bound, bound}
    assert log =~ "[info] Net: listening on #{bound}\n"
    assert log =~ "[debug] Net: connection accepted, peer 127.0.0.1:"
  end

  test "a send that fails closes with one warning and no client-close line" do
    :persistent_term.put({SlowHandler, :test}, self())
    {listener, port} = listen(SlowHandler)
    {socket, cipher} = connect(port, linger: {true, 0})
    {req, _cipher} = frame(cipher, <<0x07, 0x08, 0, 0>>)
    pid = conn_pid(listener)
    ref = Process.monitor(pid)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.send(socket, req)
        assert_receive :request_taken, 2000
        :ok = :gen_tcp.close(socket)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
      end)

    one_close(log, "[warning] Net: connection closed: send failed, peer 127.0.0.1:")
    refute log =~ "closed by the client"
  end

  test "a close by the client writes one debug line and nothing above" do
    {listener, port} = listen(QuietHandler)
    {socket, _cipher} = connect(port)
    pid = conn_pid(listener)
    ref = Process.monitor(pid)

    log =
      TestLog.capture(fn ->
        :ok = :gen_tcp.close(socket)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
      end)

    assert length(String.split(log, "[debug] Net: connection closed by the client, peer 127.0.0.1:")) == 2
    refute log =~ "[info]"
    refute log =~ "[warning]"
    refute log =~ "[error]"
  end

  test "cluster message goes to handle_info" do
    {listener, port} = listen(EffectHandler)
    {socket, _cipher} = connect(port)
    send(conn_pid(listener), {:cluster, :x})
    assert {:ok, <<4, 0x07, 0x08, 4, 0>>} = :gen_tcp.recv(socket, 5, 1000)
    closed(socket)
  end

  test "a cluster call goes to handle_call: its reply comes back and its effects run" do
    {listener, port} = listen(CallHandler)
    {socket, _cipher} = connect(port)
    assert GenServer.call(conn_pid(listener), {:cluster, :q}) == :answer
    assert {:ok, <<4, 0x07, 0x08, 5, 0>>} = :gen_tcp.recv(socket, 5, 1000)
  end

  test "the end of a process monitored in perform reaches handle_info as {:down, pid}" do
    {listener, port} = listen(CallHandler)
    {socket, _cipher} = connect(port)
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    send(conn_pid(listener), {:cluster, {:watch, pid}})
    assert {:ok, <<4, 0x07, 0x08, 7, 0>>} = :gen_tcp.recv(socket, 5, 1000)
    send(pid, :stop)
    assert {:ok, <<4, 0x07, 0x08, 6, 0>>} = :gen_tcp.recv(socket, 5, 1000)
  end

  describe "terminate/1" do
    setup do
      Process.register(self(), :connection_test)
      :ok
    end

    test "runs once on a close by the client, its lines after the close line" do
      {listener, port} = listen(EndHandler)
      {socket, _cipher} = connect(port)
      pid = conn_pid(listener)
      ref = Process.monitor(pid)

      log =
        TestLog.capture(fn ->
          :ok = :gen_tcp.close(socket)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
        end)

      assert_received :ended
      refute_received :ended
      assert log =~ ~r/connection closed by the client.*\n.*\[error\] Net: ended, peer 127\.0\.0\.1:/s
    end

    test "runs once on a close effect" do
      {listener, port} = listen(EndHandler)
      {socket, cipher} = connect(port)
      pid = conn_pid(listener)
      ref = Process.monitor(pid)
      {req, _cipher} = frame(cipher, <<0x07, 0x08, 0, 0>>)

      log =
        TestLog.capture(fn ->
          :ok = :gen_tcp.send(socket, req)
          closed(socket)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
        end)

      assert_received :ended
      refute_received :ended
      one_close(log, "[info] Net: connection closed: test, peer 127.0.0.1:")
      assert log =~ "[error] Net: ended, peer 127.0.0.1:"
    end

    test "runs once on a listener stop, after the close line" do
      {listener, port} = listen(EndHandler)
      {socket, _cipher} = connect(port)
      _ = conn_pid(listener)

      log =
        TestLog.capture(fn ->
          :ok = ThousandIsland.stop(listener)
          closed(socket)
        end)

      assert_received :ended
      refute_received :ended
      one_close(log, "[info] Net: connection closed: listener stopped, peer 127.0.0.1:")
      assert log =~ "[error] Net: ended, peer 127.0.0.1:"
    end

    test "a timer message goes to handle_info" do
      {listener, port} = listen(EndHandler)
      {socket, _cipher} = connect(port)
      send(conn_pid(listener), {:timer, :x})
      assert {:ok, <<4, 0x07, 0x08, 8, 0>>} = :gen_tcp.recv(socket, 5, 1000)

      TestLog.capture(fn ->
        :ok = :gen_tcp.close(socket)
        assert_receive :ended, 2000
      end)
    end
  end
end
