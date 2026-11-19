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

  @limits %{max_packets_per_second: 100, max_unsent_bytes: 1_048_576}

  setup do
    on_exit(fn -> :persistent_term.erase({TestClock, :now}) end)
  end

  defp listen(handler) do
    pid = start_supervised!({Net.Listener, {handler, 0, %{connection: @limits}}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{"login" => {~c"127.0.0.1", port}}
  end

  defp transcript(lines) do
    Transcript.parse!(
      "# transcript of handwritten.pcapng\n# start 100.000000\n100.000000 login#1 S 0x0807 6301\n" <> lines <> "\n"
    )
  end

  defp run(handler, lines, opts \\ []) do
    endpoints = listen(handler)
    Replay.run(transcript(lines), Keyword.merge([stop: :end, endpoints: endpoints, timeout: 200], opts))
  end

  @trigger "100.500000 login#1 C 0x0807 "
  @reply "100.600000 login#1 S 0x7F01 "

  test "pass, and the clock is moved to the capture time" do
    assert run(Stub, @trigger <> "0100\n" <> @reply <> "0100efbeadde0700", masks: [{Reply, :token, "test"}]) == :ok
    assert :persistent_term.get({TestClock, :now}) == 100_500_000
    assert TestClock.system_time(:millisecond) == 100_500
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
                     26_11_15_37_login-heartbeat-refusals-delete 26_11_16_37b_char-select-rename-refusals) do
        "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Transcript.read!() |> Map.fetch!(:packets) |> length()
      end

    assert counts == [26, 44, 30, 122, 495]
  end

  test "test client" do
    {:ok, {_address, port}} =
      ThousandIsland.listener_info(start_supervised!({Net.Listener, {Stub, 0, %{connection: @limits}}}))

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
