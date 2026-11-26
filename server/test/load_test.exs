defmodule LoadTest do
  # The code of the CI job load-smoke (docs/technical/load-run.md, "CI smoke run") against the test application:
  # prepare, place on Rou (not the start map RouN), run with 3 players over real sockets.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureIO

  setup do
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "Rou")) end)
    :ok = TestSessions.wait_none()
    Persistence.Repo.active().query!("DELETE FROM accounts")
    md5 = Base.encode16(:crypto.hash(:md5, "load"), case: :lower)
    for i <- 1..3, do: {:ok, _} = Persistence.create_account("load000#{i}", md5)
    data_dir = System.fetch_env!("PINATA_TEST_DATA_DIR")
    file = Path.join(Path.expand(System.tmp_dir!()), "pinata-load-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(file) end)
    {:ok, options} = Load.parse(~w(--scenario crowd --players 3 --map Rou --data-dir #{data_dir}))
    options = %{options | port: TestPorts.app().login, chat_ms: 500, ping_ms: 500}
    %{options: options, data_dir: data_dir, path: file}
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  test "prepare, place and run 3 players", %{options: options, data_dir: data_dir, path: file} do
    {result, _out} = with_io(fn -> Load.run(%{options | prepare: file}) end)
    assert result.prepared == 3 and Load.ok?(result)

    {:ok, block} = GameData.BlockData.load(data_dir, "Rou")
    lines = file |> File.read!() |> String.split("\n", trim: true)

    placed =
      for {line, i} <- Enum.with_index(lines, 1), into: %{} do
        ["load000" <> n, "Rou", x, y] = String.split(line, ",")
        assert n == Integer.to_string(i)
        {x, y} = {String.to_integer(x), String.to_integer(y)}
        refute GameData.BlockData.blocked?(block, x, y)
        {i, {"Rou", x, y}}
      end

    assert length(lines) == 3
    assert capture_io(File.read!(file), fn -> Persistence.Release.place_characters() end) =~ "Placed 3 characters."

    {result, out} = with_io(fn -> Load.run(%{options | hold_ms: 2500, stop_after_hold: true}) end)
    assert out =~ ~r/hold started\n(.|\n)*hold complete\n/
    assert Load.ok?(result)
    # Rou is not the start map (RouN): map and position at entry come from the placement
    assert result.in_world == 3 and result.maps == %{"Rou" => 3}
    assert result.entered == placed
    assert result.moves > 0 and result.moves_refused == 0 and result.chats > 0 and result.rtt != []
    :ok = TestSessions.wait_none()
  end

  test "a move target is one the server accepts", %{data_dir: data_dir} do
    {:ok, block} = GameData.BlockData.load(data_dir, "RouN")
    Random.seed(1)
    [line] = Load.Placement.list(:crowd, ["a"], data_dir, "RouN", ["RouN"])
    [_, _, x, y] = String.split(line, ",")

    Enum.reduce(1..2000, {String.to_integer(x), String.to_integer(y)}, fn _, pos ->
      {tx, ty} = to = Load.Player.target(block, pos)
      assert to != pos and GameData.BlockData.free_cell?(block, tx, ty)
      refute GameData.BlockData.line_blocked?(block, pos, to, 2)
      to
    end)
  end

  test "placement of the World scenario and the options", %{data_dir: data_dir} do
    maps = Load.Placement.maps(data_dir)
    assert length(maps) == 88
    names = for i <- 1..5, do: "load000#{i}"
    lines = Load.Placement.list(:world, names, data_dir, "Rou", maps)
    assert Enum.map(Enum.take(lines, 2), &Enum.at(String.split(&1, ","), 1)) == Enum.take(maps, 2)

    assert {:ok, %{scenario: :world, players: 5, hold_ms: 300_000, port: 9010, host: ~c"127.0.0.1"}} =
             Load.parse(~w(--scenario world --players 5))

    assert {:error, _usage} = Load.parse(~w(--players 5))
    assert {:error, _usage} = Load.parse(~w(--scenario mars --players 5))
    assert {:error, _usage} = Load.parse(~w(--scenario crowd --players 0))
  end
end
