defmodule Zone.MapInstanceTest do
  # Moves the global clock source and kills an instance of the application.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp dir, do: System.fetch_env!("PINATA_TEST_DATA_DIR")
  defp start(name, data_dir \\ dir()), do: start_supervised!({Zone.MapInstance, {200, name, data_dir}}, id: name)

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
    first = TestLog.capture(fn -> assert :ok = Zone.MapInstance.enter(pid, 1) end)
    assert first =~ "[info] Zone: map Rou: block data loaded, "
    assert %GameData.BlockData{} = :sys.get_state(pid).block_data
    assert TestLog.capture(fn -> assert :ok = Zone.MapInstance.enter(pid, 2) end) == ""
  end

  test "a block data file that cannot be read refuses the entry", %{tmp_dir: tmp_dir} do
    pid = start("Rou", tmp_dir)
    log = TestLog.capture(fn -> assert {:error, :no_block_data} = Zone.MapInstance.enter(pid, 1) end)
    assert log =~ "[error] Zone: map Rou: BlockInfo/Rou.shbd: file not found"
    assert :sys.get_state(pid).players == MapSet.new()
    assert Process.alive?(pid)
  end

  test "it ticks every 100 ms while it has players" do
    Application.put_env(:pinata, :clock_source, TestClock)
    on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)
    TestClock.set(1_000_000)
    pid = start("Rou")
    idle = start("RouCos01")
    :ok = Zone.MapInstance.enter(pid, 1)
    TestClock.set(2_000_000)
    assert :sys.get_state(pid).ticks == 10
    :ok = Zone.MapInstance.leave(pid, 1)
    TestClock.set(3_000_000)
    assert :sys.get_state(pid).ticks == 10
    assert :sys.get_state(idle).ticks == 0
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
    :ok = Zone.MapInstance.enter(pid, 1)
    TestClock.set(1_100_000)
    assert_receive {:telemetry, [:pinata, :tick, :stop], %{duration: _}, %{world: 200, map: "Rou"}}, 1000
  end

  test "a crashed instance comes back empty and is logged once" do
    {:ok, old} = Zone.MapInstance.whereis(0, "RouCos01")
    :ok = Zone.MapInstance.enter(old, 1)

    log =
      TestLog.capture(fn ->
        Process.exit(old, :kill)
        wait_for_new(old)
        _ = :sys.get_state(Zone.Maps)
      end)

    {:ok, new} = Zone.MapInstance.whereis(0, "RouCos01")
    assert %{players: players, block_data: nil} = :sys.get_state(new)
    assert players == MapSet.new()
    assert [_] = Regex.scan(~r/\[error\] Zone: map instance RouCos01 of world 0 crashed/, log)
  end

  defp wait_for_new(old, tries \\ 100) do
    case Zone.MapInstance.whereis(0, "RouCos01") do
      {:ok, pid} when pid != old -> :ok
      _ when tries > 0 -> Process.sleep(10) && wait_for_new(old, tries - 1)
    end
  end
end
