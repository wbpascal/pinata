defmodule Zone.MapInstanceTest do
  # Moves the global clock source and kills an instance of the application.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp dir, do: System.fetch_env!("PINATA_TEST_DATA_DIR")
  defp start(name, data_dir \\ dir()), do: start_supervised!({Zone.MapInstance, {200, name, data_dir}}, id: name)

  defp player(conn \\ :none) do
    character = %{
      id: 1,
      slot: 0,
      name: "P",
      level: 1,
      exp: 0,
      login_map: "Rou",
      login_x: 0,
      login_y: 0,
      hp: 1,
      sp: 1,
      money: 0,
      hp_stones: 0,
      sp_stones: 0,
      race: 0,
      class: 1,
      gender: 0,
      hair: 0,
      hair_color: 0,
      face: 0,
      equipment: []
    }

    %Zone.Player{
      character: character,
      world_no: 200,
      map: "Rou",
      x: 0,
      y: 0,
      walk_speed: 33,
      run_speed: 127,
      map_type: 0,
      equipment: [],
      address: "127.0.0.1",
      conn: conn
    }
  end

  test "NPCs are placed with consecutive handles" do
    state = "Rou" |> start() |> :sys.get_state()
    rows = GameData.lookup(GameData.ShineNpc, :map, "Rou")
    assert length(state.npcs) == length(rows)
    assert Enum.map(state.npcs, & &1.handle) == Enum.to_list(17_084..(17_083 + length(rows)))

    assert Enum.all?(
             GameData.plain_field_maps(),
             &(length(GameData.lookup(GameData.ShineNpc, :map, &1.map_id_client)) <= 256)
           )
  end

  test "block data is read at the first entry only" do
    pid = start("Rou")
    assert :sys.get_state(pid).block_data == nil
    first = TestLog.capture(fn -> assert {:ok, 8000} = Zone.MapInstance.enter(pid, player()) end)
    assert first =~ "[info] Zone: map Rou: block data loaded, "
    assert %GameData.BlockData{} = :sys.get_state(pid).block_data
    assert TestLog.capture(fn -> assert {:ok, 8001} = Zone.MapInstance.enter(pid, player()) end) == ""
  end

  test "a block data file that cannot be read refuses the entry", %{tmp_dir: tmp_dir} do
    pid = start("Rou", tmp_dir)
    log = TestLog.capture(fn -> assert {:error, :no_block_data} = Zone.MapInstance.enter(pid, player()) end)
    assert log =~ "[error] Zone: map Rou: BlockInfo/Rou.shbd: file not found"
    assert :sys.get_state(pid).players == %{}
    assert Process.alive?(pid)
  end

  test "it ticks every 100 ms while it has players" do
    Application.put_env(:pinata, :clock_source, TestClock)
    on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)
    TestClock.set(1_000_000)
    pid = start("Rou")
    idle = start("RouCos01")
    {:ok, 8000} = Zone.MapInstance.enter(pid, player())
    TestClock.set(2_000_000)
    assert :sys.get_state(pid).ticks == 10
    :ok = Zone.MapInstance.leave(pid, 8000)
    TestClock.set(3_000_000)
    assert :sys.get_state(pid).ticks == 10
    assert :sys.get_state(idle).ticks == 0
  end

  test "handles count up and a freed handle is not reused before the wrap" do
    pid = start("Rou")
    assert {:ok, 8000} = Zone.MapInstance.enter(pid, player())
    assert {:ok, 8001} = Zone.MapInstance.enter(pid, player())
    :ok = Zone.MapInstance.leave(pid, 8000)
    assert {:ok, 8002} = Zone.MapInstance.enter(pid, player())
    assert %{handle: 8002, mode: 0} = :sys.get_state(pid).players[8002]

    # at the end of the range the count wraps and skips the handles in use
    :sys.replace_state(pid, &%{&1 | next_handle: 9499})
    assert {:ok, 9499} = Zone.MapInstance.enter(pid, player())
    assert {:ok, 8000} = Zone.MapInstance.enter(pid, player())
    assert {:ok, 8003} = Zone.MapInstance.enter(pid, player())
  end

  test "1500 players fill the map" do
    pid = start("Rou")
    {:ok, _} = Zone.MapInstance.enter(pid, player())
    one = :sys.get_state(pid).players[8000]
    :sys.replace_state(pid, &%{&1 | players: Map.new(8000..9499, fn h -> {h, %{one | handle: h}} end)})
    assert {:error, :full} = Zone.MapInstance.enter(pid, player())
  end

  test "login_complete sets mode 1 once and returns the burst" do
    pid = start("Rou")
    {:ok, handle} = Zone.MapInstance.enter(pid, player())

    assert {:ok, [%Proto.Packets.CharClientCardcollectCmd{} | _] = packets} =
             Zone.MapInstance.login_complete(pid, handle)

    assert packets == Zone.MapEntry.login_complete(%{:sys.get_state(pid).players[handle] | mode: 0})
    assert :sys.get_state(pid).players[handle].mode == 1
    assert {:error, :not_entered} = Zone.MapInstance.login_complete(pid, handle)
    assert {:error, :not_entered} = Zone.MapInstance.login_complete(pid, 9000)
  end

  test "the end of a monitored connection removes its player" do
    pid = start("Rou")
    conn = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, handle} = Zone.MapInstance.enter(pid, player(conn))
    {:ok, other} = Zone.MapInstance.enter(pid, player())
    send(conn, :stop)
    wait_until(fn -> not Map.has_key?(:sys.get_state(pid).players, handle) end)
    assert Map.keys(:sys.get_state(pid).players) == [other]
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  @doc false
  @spec forward([atom()], map(), map(), pid()) :: term()
  def forward(event, measurements, metadata, test), do: send(test, {:telemetry, event, measurements, metadata})

  test "each tick is a telemetry span with world and map" do
    id = "map-instance-test-#{inspect(self())}"
    :ok = :telemetry.attach_many(id, [[:pinata, :tick, :stop]], &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    Application.put_env(:pinata, :clock_source, TestClock)
    on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)
    TestClock.set(1_000_000)
    pid = start("Rou")
    {:ok, 8000} = Zone.MapInstance.enter(pid, player())
    TestClock.set(1_100_000)
    assert_receive {:telemetry, [:pinata, :tick, :stop], %{duration: _}, %{world: 200, map: "Rou"}}, 1000
  end

  test "a crashed instance comes back empty and is logged once" do
    {:ok, old} = Zone.MapInstance.whereis(0, "RouCos01")
    {:ok, _handle} = Zone.MapInstance.enter(old, player())

    log =
      TestLog.capture(fn ->
        Process.exit(old, :kill)
        wait_for_new(old)
        _ = :sys.get_state(Zone.Maps)
      end)

    {:ok, new} = Zone.MapInstance.whereis(0, "RouCos01")
    assert %{players: players, block_data: nil} = :sys.get_state(new)
    assert players == %{}
    assert [_] = Regex.scan(~r/\[error\] Zone: map instance RouCos01 of world 0 crashed/, log)
  end

  defp wait_for_new(old, tries \\ 100) do
    case Zone.MapInstance.whereis(0, "RouCos01") do
      {:ok, pid} when pid != old -> :ok
      _ when tries > 0 -> Process.sleep(10) && wait_for_new(old, tries - 1)
    end
  end
end
