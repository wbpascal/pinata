defmodule Replay.HarnessTest do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.MiscHeartbeatAck
  alias Proto.Packets.MiscHeartbeatReq
  alias Proto.Packets.MiscSeedAck
  alias Replay.Failure
  alias Replay.Masks
  alias Replay.Transcript

  defmodule Reply do
    @moduledoc false
    use Proto.Packet, opcode: 0x7F01

    field :code, :u16
    field :token, :u32
    field :handle, :u16
  end

  defmodule Item do
    @moduledoc false
    use Proto.Packet

    field :id, :u16
    field :qty, :u8
  end

  defmodule Box do
    @moduledoc false
    use Proto.Packet, opcode: 0x7F02

    field :head, :u8
    field :inner, Item
    array :items, Item, count: :u8
  end

  defmodule Enter do
    @moduledoc false
    use Proto.Packet, opcode: 0x7F03

    field :map, {:char, 12}
  end

  defmodule Gone do
    @moduledoc false
    use Proto.Packet, opcode: 0x7F04

    field :handle, :u16
  end

  defmodule About do
    @moduledoc false
    use Proto.Packet, opcode: 0x7F05

    field :handle, :u16
  end

  defmodule Stub do
    @moduledoc false
    @behaviour Net.Handler

    @reply %Reply{code: 1, token: 0xDEADBEEF, handle: 7}

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: 1}), do: {state, [{:send, @reply}]}
    def handle_packet(state, %MiscSeedAck{seed: 2}), do: {state, [{:send, @reply}, {:send, @reply}]}
    def handle_packet(state, %MiscSeedAck{seed: 3}), do: {state, []}
    def handle_packet(state, %MiscSeedAck{seed: 4}), do: {state, [{:send, %MiscHeartbeatReq{}}, {:send, @reply}]}
  end

  defmodule EchoHandle do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: seed}), do: {state, [{:send, %Reply{code: 1, token: 0, handle: seed}}]}
  end

  defmodule EchoHandlePlusOne do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: seed}),
      do: {state, [{:send, %Reply{code: 1, token: 0, handle: rem(seed + 1, 65_536)}}]}
  end

  # schedules a tick through Clock.send_after/3; each tick sends one reply and schedules the next
  defmodule Ticker do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: 1}) do
      Clock.send_after(self(), {:cluster, :tick}, 100)
      {state, []}
    end

    @impl Net.Handler
    def handle_info(state, {:cluster, :tick}) do
      Clock.send_after(self(), {:cluster, :tick}, 100)
      {state, [{:send, %Reply{code: 1, token: 0xDEADBEEF, handle: 7}}]}
    end
  end

  # the token is the clock at the moment the packet is handled
  defmodule Tokener do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: 1}),
      do: {state, [{:send, %Reply{code: 1, token: rem(Clock.system_time(:millisecond), 4_294_967_296), handle: 7}}]}
  end

  # answers, then closes the connection
  defmodule Refuser do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: 1}),
      do: {state, [{:send, %Reply{code: 1, token: 0, handle: 7}}, {:close, :info, "bye"}]}
  end

  # a seed of 10, 11 or 12 enters a map; the handle of a later reply depends on the map entered
  defmodule Maps do
    @moduledoc false
    @behaviour Net.Handler

    @impl Net.Handler
    def init(_settings), do: %{base: 0}

    @impl Net.Handler
    def handle_packet(state, %MiscSeedAck{seed: 10}), do: {%{state | base: 100}, [{:send, %Enter{map: "A"}}]}
    def handle_packet(state, %MiscSeedAck{seed: 11}), do: {%{state | base: 200}, [{:send, %Enter{map: "B"}}]}
    def handle_packet(state, %MiscSeedAck{seed: 12}), do: {%{state | base: 300}, [{:send, %Enter{map: "A"}}]}

    def handle_packet(state, %MiscSeedAck{seed: 1}),
      do: {state, [{:send, %Reply{code: 1, token: 0, handle: state.base}}]}
  end

  @limits %{max_packets_per_second: 100, max_unsent_bytes: 1_048_576}

  setup do
    on_exit(fn ->
      TestClock.reset()
      :persistent_term.erase({TestClock, :now})
    end)
  end

  defp listen(handler) do
    pid = start_supervised!({Net.Listener, {"Net", handler, 0, %{connection: @limits}}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{"login" => {~c"127.0.0.1", port}, "zone" => {~c"127.0.0.1", port}}
  end

  # one seed line per connection first
  defp transcript(lines, conns \\ ["login#1"]) do
    seeds = for conn <- conns, do: "100.000000 #{conn} S 0x0807 6301\n"
    Transcript.parse!("# transcript of handwritten.pcapng\n# start 100.000000\n" <> Enum.join(seeds) <> lines <> "\n")
  end

  defp run(handler, lines, opts \\ []) do
    {conns, opts} = Keyword.pop(opts, :conns, ["login#1"])
    endpoints = listen(handler)
    Replay.run(transcript(lines, conns), Keyword.merge([stop: :end, endpoints: endpoints, timeout: 200], opts))
  end

  @trigger "100.500000 login#1 C 0x0807 "
  @reply "100.600000 login#1 S 0x7F01 "

  test "pass, and the clock is moved to the capture time of every line, server lines too" do
    assert run(Stub, @trigger <> "0100\n" <> @reply <> "0100efbeadde0700", masks: [{Reply, :token, "test"}]) == :ok
    assert :persistent_term.get({TestClock, :now}) == 100_600_000
    assert TestClock.system_time(:millisecond) == 100_600
  end

  test "byte mismatch names connection, index, opcode and field" do
    lines = @trigger <> "0100\n" <> @reply <> "0200efbeadde0700"

    assert {:error, %Failure{kind: :mismatch, conn: "login#1", index: 3, opcode: 0x7F01, message: message}} =
             run(Stub, lines, masks: [{Reply, :token, "test"}])

    assert message =~ "login#1"
    assert message =~ "packet index: 3"
    assert message =~ "0x7F01"
    assert message =~ "code: expected 0200, got 0100"
  end

  test "a failure on a known opcode shows its name" do
    endpoints = listen(Stub)
    transcript = Transcript.parse!("# transcript of x.pcapng\n# start 100.000000\n100.000000 login#1 S 0x0807 636363\n")

    assert {:error, %Failure{kind: :mismatch, message: message}} =
             Replay.run(transcript, stop: :end, endpoints: endpoints)

    assert message =~ "0x0807 NC_MISC_SEED_ACK"
    assert message =~ "size: expected 3, got 2"
  end

  test "masked field" do
    lines = @trigger <> "0100\n" <> @reply <> "0100aaaaaaaa0700"
    assert {:error, %Failure{kind: :mismatch}} = run(Stub, lines)
    assert run(Stub, lines, masks: [{Reply, :token, "test: random token"}]) == :ok
  end

  test "missing packet" do
    lines = @trigger <> "0300\n" <> @reply <> "0100efbeadde0700"
    assert {:error, %Failure{kind: :missing, index: 3}} = run(Stub, lines)
  end

  test "extra packet, and unexpected packet" do
    lines = @trigger <> "0200\n" <> @reply <> "0100efbeadde0700"
    assert {:error, %Failure{kind: :extra}} = run(Stub, lines)

    more = lines <> "\n100.700000 login#1 S 0x7F02 00"
    assert {:error, %Failure{kind: :unexpected, index: 4}} = run(Stub, more, masks: [{Box, :head, "test"}])
  end

  test "before: the function of an index runs before that client packet is sent" do
    me = self()
    lines = @trigger <> "0100\n" <> @reply <> "0100efbeadde0700"
    before = %{2 => fn -> send(me, :before_2) end, 3 => fn -> send(me, :before_3) end}

    assert run(Stub, lines, masks: [{Reply, :token, "test"}], before: before) == :ok
    assert_received :before_2
    assert_received :before_3
  end

  test "close_after: closes the connection of that packet, so no extra packet is drained" do
    lines = @trigger <> "0200\n" <> @reply <> "0100efbeadde0700"
    assert run(Stub, lines, close_after: [3]) == :ok
  end

  test "sync_after: the heartbeat round trip is consumed and not reported as extra" do
    lines = @trigger <> "0100\n" <> @reply <> "0100efbeadde0700"
    assert run(Stub, lines, sync_after: [1]) == :ok
  end

  test "timer-driven opcodes are dropped and not expected" do
    assert run(Stub, @trigger <> "0400\n" <> @reply <> "0100efbeadde0700") == :ok
    assert run(Stub, "100.100000 login#1 S 0x0804 -") == :ok
  end

  test "stop point" do
    lines = @trigger <> "0100\n" <> @reply <> "0100efbeadde0700\n100.700000 login#1 S 0x7F01 ffffffffffffffff"
    assert run(Stub, lines, stop: 3) == :ok
    assert {:error, %Failure{index: 4}} = run(Stub, lines)
  end

  describe "ticks" do
    @tick_lines @trigger <> "0100\n" <> @reply <> "0100efbeadde0700\n100.700000 login#1 S 0x7F01 0100efbeadde0700"

    test "a tick scheduled through Clock.send_after fires at its captured time" do
      assert run(Ticker, @tick_lines, sync_after: [2]) == :ok
    end

    test "tick_offset moves the first tick of a train only" do
      assert {:error, %Failure{kind: :missing}} = run(Ticker, @tick_lines, sync_after: [2], tick_offset: 50)

      shifted =
        @trigger <>
          "0100\n100.650000 login#1 S 0x7F01 0100efbeadde0700\n100.750000 login#1 S 0x7F01 0100efbeadde0700"

      assert run(Ticker, shifted, sync_after: [2], tick_offset: 50) == :ok
    end

    test "TestClock.reset delivers the pending timers and erases the offset" do
      TestClock.tick_offset(5)
      TestClock.send_after(self(), :late, 1000)
      refute_received :late
      assert TestClock.reset() == :ok
      assert_received :late
      assert :persistent_term.get({TestClock, :tick_offset}, nil) == nil
    end
  end

  describe "zone" do
    test "a heartbeat round trip follows every client packet, the answer is buffered, the clock stays" do
      # 100 500 ms = 0x00018894 little-endian
      lines = "100.500000 zone#1 C 0x0807 0100\n100.900000 zone#1 S 0x7F01 010094880100" <> "0700"
      assert run(Tokener, lines, conns: ["zone#1"]) == :ok
    end

    test "an answer followed by a close by the server is still a transcript line" do
      lines = "100.500000 zone#1 C 0x0807 0100\n100.900000 zone#1 S 0x7F01 0100000000000700"
      assert run(Refuser, lines, conns: ["zone#1"]) == :ok
    end

    test "a buffered answer nobody expects is an extra packet at the end" do
      lines = "100.500000 zone#1 C 0x0807 0100"
      assert {:error, %Failure{kind: :extra}} = run(Tokener, lines, conns: ["zone#1"])
    end
  end

  describe "handle scope per map" do
    @enter_a "41" <> String.duplicate("00", 11)
    @enter_b "42" <> String.duplicate("00", 11)
    @opts [map_names: [{Enter, :map}], conns: ["zone#1", "zone#2"]]

    # seed 0a00 enters map A, 0b00 map B, 0c00 map A again
    defp scope_lines(first, second) do
      enter = %{"0a00" => @enter_a, "0b00" => @enter_b, "0c00" => @enter_a}

      """
      100.100000 zone#1 C 0x0807 #{first}
      100.110000 zone#1 S 0x7F03 #{enter[first]}
      100.200000 zone#2 C 0x0807 #{second}
      100.210000 zone#2 S 0x7F03 #{enter[second]}
      100.300000 zone#1 C 0x0807 0100
      100.310000 zone#1 S 0x7F01 0100000000000500
      100.400000 zone#2 C 0x0807 0100
      100.410000 zone#2 S 0x7F01 0100000000000500
      """
      |> String.trim()
    end

    test "two clients in different maps share captured handles with different received values" do
      handles = [{Reply, :handle, :object, "test"}]
      assert run(Maps, scope_lines("0a00", "0b00"), [handles: handles] ++ @opts) == :ok
    end

    test "two clients in the same map must agree" do
      handles = [{Reply, :handle, :object, "test"}]

      assert {:error, %Failure{kind: :handle, conn: "zone#2"}} =
               run(Maps, scope_lines("0a00", "0c00"), [handles: handles] ++ @opts)
    end

    test "another namespace is global" do
      handles = [{Reply, :handle, :other, "test"}]

      assert {:error, %Failure{kind: :handle}} =
               run(Maps, scope_lines("0a00", "0b00"), [handles: handles] ++ @opts)
    end
  end

  describe "0xFFFF" do
    @ffff [{Reply, :handle, :object, "test"}, {MiscSeedAck, :seed, :object, "test"}]

    test "passes unmapped, next to a bound handle" do
      lines = """
      100.500000 login#1 C 0x0807 ffff
      100.510000 login#1 S 0x7F01 010000000000ffff
      100.520000 login#1 C 0x0807 6301
      100.530000 login#1 S 0x7F01 0100000000006301
      100.540000 login#1 C 0x0807 ffff
      100.550000 login#1 S 0x7F01 010000000000ffff
      """

      assert run(EchoHandle, String.trim(lines), handles: @ffff) == :ok
    end

    test "captured ffff received as another value fails" do
      lines = "100.500000 login#1 C 0x0807 6301\n100.510000 login#1 S 0x7F01 010000000000ffff"
      assert {:error, %Failure{kind: :handle, message: message}} = run(EchoHandle, lines, handles: @ffff)
      assert message =~ "ffff must stay ffff"
    end
  end

  describe "handle map" do
    @handles [{MiscSeedAck, :seed, :h, "test"}, {Reply, :handle, :h, "test"}]
    @lines "100.500000 login#1 C 0x0807 6301\n" <> @reply <> "0100000000006301"

    test "consistent, and the client packet is rewritten" do
      assert run(EchoHandle, @lines, handles: @handles) == :ok
    end

    test "inconsistent" do
      assert {:error, %Failure{kind: :handle, message: message}} = run(EchoHandlePlusOne, @lines, handles: @handles)
      assert message =~ "handle: original 6301 is bound to"
    end

    test "a client identifier the server never sent" do
      lines = "100.500000 login#1 C 0x0807 6302\n"
      handles = [{Reply, :handle, :h, "test"}, {MiscSeedAck, :seed, :h, "test"}]
      assert {:error, %Failure{kind: :handle}} = run(EchoHandle, lines, handles: handles, masks: [])
    end
  end

  describe "deferrals" do
    @good @trigger <> "0100\n" <> @reply <> "0100efbeadde0700"

    test "payload of the whole packet: any size, but the opcode still counts" do
      lines = @trigger <> "0100\n" <> @reply <> "0100"
      assert {:error, %Failure{kind: :mismatch}} = run(Stub, lines)
      assert run(Stub, lines, deferrals: [{:payload, Reply, :all, 3, "r"}]) == :ok

      other = @trigger <> "0100\n100.600000 login#1 S 0x7F02 00"

      assert {:error, %Failure{kind: :unexpected}} =
               run(Stub, other, deferrals: [{:payload, Reply, :all, 3, "r"}])
    end

    test "payload of a field acts like a mask" do
      lines = @trigger <> "0100\n" <> @reply <> "0100aaaaaaaa0700"
      assert {:error, %Failure{kind: :mismatch}} = run(Stub, lines)
      assert run(Stub, lines, deferrals: [{:payload, Reply, :token, 4, "r"}]) == :ok
    end

    test "absent: the packet is taken out of the transcript" do
      lines = @good <> "\n100.700000 login#1 S 0x7F02 00"
      assert {:error, %Failure{kind: :missing}} = run(Stub, lines)
      assert run(Stub, lines, deferrals: [{:absent, Box, 4, "r"}]) == :ok
    end

    test "unsent: a client packet and its answers are left out, the replay continues" do
      lines =
        "100.400000 login#1 C 0x0807 0200\n" <>
          "100.410000 login#1 S 0x7F01 0100efbeadde0700\n100.420000 login#1 S 0x7F01 0100efbeadde0700\n" <> @good

      assert run(Stub, lines, deferrals: [{:unsent, 2, [3, 4], 3, "r"}]) == :ok
    end

    test "validation" do
      packets = transcript(@good).packets
      assert Replay.Deferrals.validate!([{:absent, Box, 4, "r"}, {:unsent, 2, [3], 3, "r"}], packets) == :ok
      assert_raise ArgumentError, ~r/reason/, fn -> Replay.Deferrals.validate!([{:absent, Box, 4, ""}], packets) end
      assert_raise ArgumentError, ~r/milestone/, fn -> Replay.Deferrals.validate!([{:absent, Box, 0, "r"}], packets) end

      assert_raise ArgumentError, ~r/no field :nope/, fn ->
        Replay.Deferrals.validate!([{:payload, Reply, :nope, 3, "r"}], packets)
      end

      assert_raise ArgumentError, ~r/not a client packet/, fn ->
        Replay.Deferrals.validate!([{:unsent, 1, [3], 3, "r"}], packets)
      end

      assert_raise ArgumentError, ~r/not a server packet/, fn ->
        Replay.Deferrals.validate!([{:unsent, 2, [2], 3, "r"}], packets)
      end

      assert_raise ArgumentError, ~r/malformed/, fn -> Replay.Deferrals.validate!([{:bogus, 1}], packets) end
    end
  end

  describe "mob exclusion" do
    @a "41" <> String.duplicate("00", 11)
    @mob_lines """
    100.100000 zone#1 S 0x7F03 #{@a}
    100.110000 zone#1 S 0x7F01 0100000000000a00
    100.120000 zone#1 S 0x7F01 0200000000000b00
    100.130000 zone#1 S 0x7F05 0b00
    100.140000 zone#1 S 0x7F05 0a00
    100.150000 zone#1 C 0x0807 0b00
    100.160000 zone#1 C 0x0807 0a00
    100.170000 zone#1 S 0x7F02 00000000020a0001 0c0002
    100.180000 zone#1 S 0x7F02 00000000020d0002 0e0002
    100.190000 zone#1 S 0x7F04 0b00
    100.200000 zone#1 S 0x7F05 0b00
    100.210000 zone#2 S 0x7F05 0b00
    100.220000 zone#1 S 0x7F04 0a00
    100.230000 zone#1 S 0x7F05 0c00
    """

    defp mobs do
      me = self()

      %{
        appear: [{Reply, :handle, :code}],
        lists: [{Box, :items, :id, :qty}],
        gone: [{Gone, :handle}],
        about: [{About, :handle}, {MiscSeedAck, :seed}],
        npc?: fn map, id ->
          send(me, {:npc, map, id})
          id == 1
        end
      }
    end

    test "per connection, until gone, lists reduced or taken out" do
      lines = String.replace(@mob_lines, " 0c0002", "0c0002") |> String.replace(" 0e0002", "0e0002")
      transcript = transcript(String.trim(lines), ["zone#1", "zone#2"])

      packets =
        Replay.Deferrals.apply(transcript.packets, [{:mobs, mobs(), 3, "r"}], [{Enter, :map}])

      # the seed lines are 1 and 2; NPC appear 4 kept, mob appear 5 out, about 6 out, about of the NPC 7 kept,
      # client on the mob 8 out, on the NPC 9 kept, list 10 reduced, list of mobs 11 out, gone 12 out,
      # about 13 kept again, second connection 14 kept, gone of the NPC 15 kept, about of a listed mob 16 out
      assert Enum.map(packets, & &1.index) == [1, 2, 3, 4, 7, 9, 10, 13, 14, 15]
      assert Enum.find(packets, &(&1.index == 10)).payload == Base.decode16!("00000000010a0001", case: :lower)
      assert Enum.find(packets, &(&1.index == 4)).scope == "A"
      assert Enum.find(packets, &(&1.index == 14)).scope == nil
      assert_received {:npc, "A", 2}
    end

    test "end to end through run/2" do
      lines = @trigger <> "0100\n" <> @reply <> "0100efbeadde0700\n100.650000 login#1 S 0x7F01 0200efbeadde0900"
      assert {:error, %Failure{}} = run(Stub, lines)
      assert run(Stub, lines, deferrals: [{:mobs, mobs(), 3, "r"}]) == :ok
    end
  end

  describe "replay cut" do
    @cut_lines @trigger <> "0100\n" <> @reply <> "0100efbeadde0700\n100.700000 login#1 S 0x7F01 ffffffffffffffff"

    test "lines at or after the seconds are not played" do
      assert {:error, %Failure{index: 4}} = run(Stub, @cut_lines)
      assert run(Stub, @cut_lines, stop: {:cut, 0.65, "the rest needs the map instance"}) == :ok
    end

    test "the reason is one line of text" do
      assert_raise ArgumentError, ~r/reason/, fn -> run(Stub, @cut_lines, stop: {:cut, 0.65, ""}) end
      assert_raise ArgumentError, ~r/reason/, fn -> run(Stub, @cut_lines, stop: {:cut, 0.65, "a\nb"}) end
    end
  end

  describe "drop_after" do
    test "the server side of the connection is killed and the client sees the close" do
      lines = @trigger <> "0100\n" <> @reply <> "0100efbeadde0700"
      assert run(Stub, lines, drop_after: [3]) == :ok
    end

    test "a packet the transcript does not hold is an extra packet" do
      lines = @trigger <> "0200\n" <> @reply <> "0100efbeadde0700"
      assert {:error, %Failure{kind: :extra}} = run(Stub, lines, drop_after: [3])
    end

    test "a connection whose remote port equals the client's port is left alone" do
      endpoints = listen(Stub)
      {_host, server_port} = endpoints["login"]
      test = self()
      loopback6 = {0, 0, 0, 0, 0, 0, 0, 1}

      # Before packet 2 the client is connected: listen on its port number over IPv6 and connect a decoy there.
      decoy = fn ->
        [client_port] =
          for port <- Port.list(),
              Port.info(port, :name) == {:name, ~c"tcp_inet"},
              match?({:ok, {_address, ^server_port}}, :inet.peername(port)),
              {:ok, {_address, client_port}} <- [:inet.sockname(port)],
              do: client_port

        {:ok, listener} = :gen_tcp.listen(client_port, [:inet6, active: false, ip: loopback6])

        pid =
          spawn(fn ->
            {:ok, socket} = :gen_tcp.connect(loopback6, client_port, [:inet6, active: false])
            send(test, :decoy_ready)
            receive do: (:stop -> :gen_tcp.close(socket))
          end)

        assert_receive :decoy_ready
        send(test, {:decoy, pid, listener})
        :ok
      end

      lines = @trigger <> "0100\n" <> @reply <> "0100efbeadde0700"
      opts = [stop: :end, endpoints: endpoints, timeout: 200, drop_after: [3], before: %{2 => decoy}]
      assert Replay.run(transcript(lines), opts) == :ok

      assert_received {:decoy, pid, listener}
      assert Process.alive?(pid)
      send(pid, :stop)
      :gen_tcp.close(listener)
    end
  end

  test "bad mask entries raise" do
    assert_raise ArgumentError, ~r/needs a reason/, fn -> Masks.validate!([{Reply, :token, ""}]) end
    assert_raise ArgumentError, ~r/no field :nope/, fn -> Masks.validate!([{Reply, :nope, "reason"}]) end
    assert_raise ArgumentError, fn -> Masks.validate!([{Reply, :token, :h, ""}]) end
    assert Masks.validate!(Masks.global()) == :ok
    assert Enum.all?(Masks.global(), &(elem(&1, 2) != ""))
    assert {MiscSeedAck, :seed, _reason} = List.keyfind(Masks.global(), MiscSeedAck, 0)
  end

  test "mask ranges" do
    box = <<9, 1, 0, 5, 2, 10, 0, 1, 11, 0, 2>>
    assert Box.__packet__().layout == [{:head, 0, 1, nil}, {:inner, 1, 3, Item}, {:items, 4, nil, {:array, Item, 1}}]
    assert Masks.ranges(Box, :head, box) == [{0, 1}]
    assert Masks.ranges(Box, [:inner, :qty], box) == [{3, 1}]
    assert Masks.ranges(Box, [:items, :id], box) == [{5, 2}, {8, 2}]
    assert Masks.ranges(Box, :items, box) == [{4, 7}]
    assert_raise ArgumentError, fn -> Masks.ranges(Box, [:head, :x], box) end
  end

  test "transcript parser" do
    t = Transcript.parse!("# transcript of a.pcapng (format)\n# start 1.000001\n1.000002 wm#1 C 0x080D -\n")
    assert %Transcript{capture: "a", start: 1_000_001, packets: [packet]} = t
    assert packet == %{index: 1, time: 1_000_002, conn: "wm#1", dir: :client, opcode: 0x080D, payload: <<>>}

    assert_raise ArgumentError, ~r/line 3/, fn ->
      Transcript.parse!("# transcript of a.pcapng\n# start 1.000001\nnot a packet\n")
    end

    counts =
      for name <- ~w(26_11_15_login-logout 26_11_15_login-errors 26_11_15_create-char
                     26_11_15_37_login-heartbeat-refusals-delete 26_11_16_37b_char-select-rename-refusals
                     26_11_15_idle_in_world 26_11_15_walk-run-portals 26_11_15_14_second-client-in-sight
                     26_11_16_38_session-loss-kicks-char-select
                     26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort
                     26_11_21_52_stale-tutorial-rename-kickout-shn) do
        "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Transcript.read!() |> Map.fetch!(:packets) |> length()
      end

    assert counts == [26, 44, 30, 122, 495, 208, 1057, 10_954, 2271, 1980, 1149]
  end

  test "test client" do
    {:ok, {_address, port}} =
      ThousandIsland.listener_info(start_supervised!({Net.Listener, {"Net", Stub, 0, %{connection: @limits}}}))

    client = TestClient.connect(~c"127.0.0.1", port)
    assert_raise ArgumentError, fn -> TestClient.send_raw(client, <<0x04, 0x08>>) end
    assert {:ok, %MiscSeedAck{}, client} = TestClient.recv(client)
    assert {:ok, client} = TestClient.send_packet(client, %MiscHeartbeatReq{})
    client = TestClient.expect(client, %MiscHeartbeatAck{})
    assert {:error, :timeout} = TestClient.recv(client, 50)
    assert TestClient.close(client) == :ok
  end

  describe "topology" do
    test "single, multi and others" do
      assert Replay.Topology.mode(nil) == :single
      assert Replay.Topology.mode("single") == :single
      assert Replay.Topology.mode("multi") == :multi
      assert_raise RuntimeError, ~r/PINATA_TEST_TOPOLOGY/, fn -> Replay.Topology.mode("bogus") end
      assert %{"login" => _, "wm" => _, "zone" => _} = Replay.Topology.endpoints()
    end
  end
end
