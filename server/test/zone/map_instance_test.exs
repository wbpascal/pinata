defmodule Zone.MapInstanceTest do
  # Moves the global clock source and kills an instance of the application.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp dir, do: System.fetch_env!("PINATA_TEST_DATA_DIR")
  defp start(name), do: start(name, free_dir(name))
  defp start(name, data_dir), do: start_supervised!({Zone.MapInstance, {200, name, data_dir}}, id: name)

  # A copy of the map's block data with every cell free, so that players can enter at any point; one per run and map.
  defp free_dir(name) do
    free = Path.join(System.tmp_dir!(), "pinata-free-blocks-#{System.pid()}")
    path = Path.join([free, "BlockInfo", name <> ".shbd"])

    if not File.exists?(path) do
      {:ok, <<bpr::little-32, rows::little-32>> = head} =
        File.open(Path.join([dir(), "BlockInfo", name <> ".shbd"]), [:read, :binary], &IO.binread(&1, 8))

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, head <> :binary.copy(<<0>>, bpr * rows))
    end

    free
  end

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
      admin_level: 0,
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
      last_good: {0, 0},
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
    first = TestLog.capture(fn -> assert {:ok, %{handle: 8000}} = Zone.MapInstance.enter(pid, player()) end)
    assert first =~ "[info] Zone: map Rou: block data loaded, "
    assert %GameData.BlockData{} = :sys.get_state(pid).block_data
    assert TestLog.capture(fn -> assert {:ok, %{handle: 8001}} = Zone.MapInstance.enter(pid, player()) end) == ""
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
    {:ok, %{handle: 8000}} = Zone.MapInstance.enter(pid, player())
    TestClock.set(2_000_000)
    assert :sys.get_state(pid).ticks == 10
    {:ok, %Zone.Player{handle: 8000}} = Zone.MapInstance.leave(pid, 8000)
    TestClock.set(3_000_000)
    assert :sys.get_state(pid).ticks == 10
    assert :sys.get_state(idle).ticks == 0
  end

  test "handles count up and a freed handle is not reused before the wrap" do
    pid = start("Rou")
    assert {:ok, %{handle: 8000}} = Zone.MapInstance.enter(pid, player())
    assert {:ok, %{handle: 8001}} = Zone.MapInstance.enter(pid, player())
    {:ok, %Zone.Player{handle: 8000}} = Zone.MapInstance.leave(pid, 8000)
    assert {:ok, %{handle: 8002}} = Zone.MapInstance.enter(pid, player())
    assert %{handle: 8002, mode: 0} = :sys.get_state(pid).players[8002]

    # at the end of the range the count wraps and skips the handles in use
    :sys.replace_state(pid, &%{&1 | next_handle: 9499})
    assert {:ok, %{handle: 9499}} = Zone.MapInstance.enter(pid, player())
    assert {:ok, %{handle: 8000}} = Zone.MapInstance.enter(pid, player())
    assert {:ok, %{handle: 8003}} = Zone.MapInstance.enter(pid, player())
  end

  test "enter/3 takes the given handle, refuses it in use, and enter/2 skips it" do
    pid = start("Rou")
    assert {:ok, %{handle: 8000}} = Zone.MapInstance.enter(pid, player(), 8000)
    assert %{handle: 8000, mode: 0} = :sys.get_state(pid).players[8000]
    assert {:error, :handle_taken} = Zone.MapInstance.enter(pid, player(), 8000)
    assert {:ok, %{handle: 8001}} = Zone.MapInstance.enter(pid, player())
  end

  test "1500 players fill the map" do
    pid = start("Rou")
    {:ok, %{handle: _}} = Zone.MapInstance.enter(pid, player())
    one = :sys.get_state(pid).players[8000]
    :sys.replace_state(pid, &%{&1 | players: Map.new(8000..9499, fn h -> {h, %{one | handle: h}} end)})
    assert {:error, :full} = Zone.MapInstance.enter(pid, player())
  end

  test "login_complete sets mode 1 once and returns the burst" do
    pid = start("Rou")
    {:ok, %{handle: handle}} = Zone.MapInstance.enter(pid, player())

    assert {:ok, [%Proto.Packets.CharClientCardcollectCmd{} | _] = packets} =
             Zone.MapInstance.login_complete(pid, handle)

    sight = Enum.filter(packets, &match?(%Proto.Packets.BriefinfoMobCmd{}, &1))
    assert [_ | _] = sight
    assert packets == Zone.MapEntry.login_complete(:sys.get_state(pid).players[handle], sight)
    assert :sys.get_state(pid).players[handle].mode == 1
    assert {:error, :not_entered} = Zone.MapInstance.login_complete(pid, handle)
    assert {:error, :not_entered} = Zone.MapInstance.login_complete(pid, 9000)
  end

  test "the end of a monitored connection removes its player" do
    pid = start("Rou")
    conn = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, %{handle: handle}} = Zone.MapInstance.enter(pid, player(conn))
    {:ok, %{handle: other}} = Zone.MapInstance.enter(pid, player())
    send(conn, :stop)
    wait_until(fn -> not Map.has_key?(:sys.get_state(pid).players, handle) end)
    assert Map.keys(:sys.get_state(pid).players) == [other]
  end

  test "the appear elements of NPCs: a gate and a plain NPC as captured (idle_in_world)" do
    state = "RouN" |> start() |> :sys.get_state()
    by_place = Map.new(state.npcs, &{{&1.x, &1.y}, &1})

    # the captured gate element: mob 159 at 7538, 5470, Direct 182, to Fbattle01
    gate = by_place[{7538, 5470}]

    assert %Proto.Packets.BriefinfoRegenmobCmd{mode: 2, mob_id: 159, dir: 91, flagstate: 1, kq_team_type: 2} =
             gate.brief

    assert gate.brief.flag == "Fbattle01" <> <<0::24, 0::192, 0x08, 0::496>>
    # a plain NPC: mob 29 at 7305, 8999, no flag
    assert %{mob_id: 29, dir: 30, flagstate: 0, flag: <<0::792>>} = by_place[{7305, 8999}].brief

    gates =
      for %{row: %{role: role}} = npc <- state.npcs, role in ["Gate", "IDGate", "ModeIDGate", "RandomGate"], do: npc

    assert [_ | _] = gates
    assert Enum.all?(gates, &(&1.brief.flagstate == 1))
    assert map_size(state.npc_index) == length(state.npcs)
  end

  test "a map without MapInfo row and an NPC without MobInfo row are logged at start" do
    log = TestLog.capture(fn -> start("RouCos04") end)
    assert log =~ "[info] Zone: map RouCos04: no MapInfo row, sight radius 0"
    log = TestLog.capture(fn -> start("Eld") end)
    assert log =~ "[info] Zone: map Eld: NPC KDSoccer_MctNPC not shown: no MobInfo row"
  end

  test "an exit message of a linked process is ignored" do
    pid = start("Rou")
    send(pid, {:EXIT, self(), :boom})
    assert {:error, :not_entered} = Zone.MapInstance.step(pid, 9000, {10, 10})
  end

  test "step, set_layer and inform of an unknown handle" do
    pid = start("Rou")
    assert {:error, :not_entered} = Zone.MapInstance.step(pid, 9000, {10, 10})
    assert {:error, :not_entered} = Zone.MapInstance.set_layer(pid, 9000, 1, 0)
    assert Zone.MapInstance.inform(pid, 9000, 17_084) == []
  end

  test "a player in sight that leaves is announced with 0x1805; a mode-0 player is not" do
    pid = start("Rou")
    {:ok, %{handle: me}} = Zone.MapInstance.enter(pid, player(self()))
    {:ok, _} = Zone.MapInstance.login_complete(pid, me)
    {:ok, %{handle: other}} = Zone.MapInstance.enter(pid, player())
    {:ok, _} = Zone.MapInstance.login_complete(pid, other)
    assert_receive {:cluster, {:packets, [%Proto.Packets.BriefinfoLogincharacterCmd{handle: ^other}]}}
    {:ok, _} = Zone.MapInstance.leave(pid, other)
    assert_receive {:cluster, {:packets, [%Proto.Packets.MapLogoutCmd{handle: ^other}]}}

    {:ok, %{handle: hidden}} = Zone.MapInstance.enter(pid, player())
    {:ok, _} = Zone.MapInstance.leave(pid, hidden)
    refute_receive {:cluster, _}, 50
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
    {:ok, %{handle: 8000}} = Zone.MapInstance.enter(pid, player())
    TestClock.set(1_100_000)
    assert_receive {:telemetry, [:pinata, :tick, :stop], %{duration: _}, %{world: 200, map: "Rou"}}, 1000
  end

  test "a crashed instance comes back empty and is logged once" do
    {:ok, old} = Zone.MapInstance.whereis(0, "RouCos01")
    {:ok, %{handle: _handle}} = Zone.MapInstance.enter(old, player())

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

  # a player in mode 1 at a point; the packets of its entry are flushed
  defp standing(pid, {x, y}, conn \\ :none) do
    {:ok, %{handle: handle}} = Zone.MapInstance.enter(pid, %{player(conn) | x: x, y: y, last_good: {x, y}})
    {:ok, _} = Zone.MapInstance.login_complete(pid, handle)
    flush()
    handle
  end

  defp flush do
    receive do
      {:cluster, _} -> flush()
    after
      20 -> :ok
    end
  end

  defp some_npc(pid), do: pid |> :sys.get_state() |> Map.fetch!(:npc_index) |> Map.values() |> hd()

  test "npc/3: within 1000 units of a shown NPC, not 1001 away, not an unknown handle, not in mode 0" do
    pid = start("Rou")
    npc = some_npc(pid)
    near = standing(pid, {npc.x, npc.y + 1000})
    far = standing(pid, {npc.x, npc.y + 1001})
    assert {:ok, %Zone.Npc{handle: h}, {x, y}} = Zone.MapInstance.npc(pid, near, npc.handle)
    assert {h, x, y} == {npc.handle, npc.x, npc.y + 1000}
    assert :error = Zone.MapInstance.npc(pid, far, npc.handle)
    assert :error = Zone.MapInstance.npc(pid, near, 1)
    assert :error = Zone.MapInstance.npc(pid, 9499, npc.handle)
    {:ok, %{handle: loading}} = Zone.MapInstance.enter(pid, %{player() | x: npc.x, y: npc.y, last_good: {npc.x, npc.y}})
    assert :error = Zone.MapInstance.npc(pid, loading, npc.handle)
  end

  test "near_npc?/3: by mob name within 1000 units" do
    pid = start("Rou")
    npc = some_npc(pid)
    near = standing(pid, {npc.x + 600, npc.y + 800})
    far = standing(pid, {npc.x + 601, npc.y + 800})
    assert Zone.MapInstance.near_npc?(pid, near, npc.row.mob_name)
    refute Zone.MapInstance.near_npc?(pid, near, "NoSuchMob")
    refute Zone.MapInstance.near_npc?(pid, far, npc.row.mob_name)
    refute Zone.MapInstance.near_npc?(pid, 9499, npc.row.mob_name)
  end

  test "relocate/3: the new position in mode 0, the handle kept, 0x1805 to a player in sight" do
    pid = start("Rou")
    _watcher = standing(pid, {500, 500}, self())
    mover = standing(pid, {600, 600})
    flush()
    :sys.replace_state(pid, &put_in(&1.players[mover].chat.ring, [1]))
    assert {:ok, %Zone.Player{handle: ^mover} = p} = Zone.MapInstance.relocate(pid, mover, {700, 800})
    assert {p.x, p.y, p.last_good, p.mode, p.mover, p.move, p.chat.ring} == {700, 800, {700, 800}, 0, :none, :none, []}
    assert_receive {:cluster, {:packets, [%Proto.Packets.MapLogoutCmd{handle: ^mover}]}}
    assert {:ok, ^p} = Zone.MapInstance.player(pid, mover)
    assert {:error, :not_on_map} = Zone.MapInstance.relocate(pid, 9499, {1, 1})
  end

  describe "GM actions" do
    alias Proto.Packets.BatAbstateinformNoeffectCmd
    alias Proto.Packets.BatAbstateresetCmd
    alias Proto.Packets.MapLogoutCmd

    # the GM's own packets arrive tagged, the watcher's untagged
    defp gm_conn do
      me = self()

      spawn_link(fn ->
        Stream.repeatedly(fn -> receive(do: ({:cluster, msg} -> send(me, {:gm, msg}))) end) |> Stream.run()
      end)
    end

    setup do
      pid = start("Rou")
      _watcher = standing(pid, {500, 500}, self())
      gm = standing(pid, {600, 600}, gm_conn())
      flush_gm()
      %{pid: pid, gm: gm}
    end

    defp flush_gm do
      receive do
        {:gm, _} -> flush_gm()
      after
        20 -> :ok
      end
    end

    test ":hide sends 0x1805 to those in sight and 0x242A to the GM; :show sends 0x2428 to both", %{pid: pid, gm: gm} do
      :ok = Zone.MapInstance.action(pid, gm, :hide)
      assert_receive {:cluster, {:packets, [%MapLogoutCmd{handle: ^gm}]}}
      abstate = %BatAbstateinformNoeffectCmd{abstate: 288, keep_time: 4_200_000_000}
      assert_receive {:gm, {:packets, [^abstate]}}
      assert {:ok, %Zone.Player{sub_layer: 3}} = Zone.MapInstance.player(pid, gm)

      :ok = Zone.MapInstance.action(pid, gm, :show)
      reset = %BatAbstateresetCmd{handle: gm, abstate: 288}
      assert_receive {:gm, {:packets, [^reset]}}
      assert_receive {:cluster, {:packets, [^reset]}}
      assert {:ok, %Zone.Player{sub_layer: 0}} = Zone.MapInstance.player(pid, gm)

      # not hidden: nothing
      :ok = Zone.MapInstance.action(pid, gm, :show)
      refute_receive {_, {:packets, _}}, 50
    end

    test "{:dimension, n} sends 0x1805 under the old number, then sets it, also the same number", %{pid: pid, gm: gm} do
      :ok = Zone.MapInstance.action(pid, gm, {:dimension, 1})
      assert_receive {:cluster, {:packets, [%MapLogoutCmd{handle: ^gm}]}}
      assert {:ok, %Zone.Player{dimension: 1}} = Zone.MapInstance.player(pid, gm)

      # the watcher no longer sees the GM; back to 0 announces nothing
      :ok = Zone.MapInstance.action(pid, gm, {:dimension, 0})
      refute_receive {_, {:packets, _}}, 50

      :ok = Zone.MapInstance.action(pid, gm, {:dimension, 0})
      assert_receive {:cluster, {:packets, [%MapLogoutCmd{handle: ^gm}]}}
      refute_receive {:gm, _}, 50
    end

    test "relocate/3 resets the dimension and the sub-layer", %{pid: pid, gm: gm} do
      :ok = Zone.MapInstance.set_layer(pid, gm, 5, 3)
      assert {:ok, %Zone.Player{dimension: 0, sub_layer: 0}} = Zone.MapInstance.relocate(pid, gm, {700, 700})
    end

    test "free_spot/1 draws a point whose cell is free", %{pid: pid} do
      b = :sys.get_state(pid).block_data

      for _ <- 1..20 do
        assert {:ok, {x, y}} = Zone.MapInstance.free_spot(pid)
        refute GameData.BlockData.blocked?(b, x, y)
      end

      assert :error = Zone.MapInstance.free_spot(start("RouN"))
    end
  end

  test "leave returns the player as it was on the map, player/2 reads it" do
    pid = start("Rou")
    {:ok, %{handle: handle}} = Zone.MapInstance.enter(pid, player())
    :sys.replace_state(pid, &put_in(&1.players[handle].x, 77))
    assert {:ok, %Zone.Player{handle: ^handle, x: 77}} = Zone.MapInstance.player(pid, handle)
    assert {:ok, %Zone.Player{handle: ^handle, x: 77}} = Zone.MapInstance.leave(pid, handle)
    assert :error = Zone.MapInstance.leave(pid, handle)
    assert :error = Zone.MapInstance.player(pid, handle)
  end

  test "stopped in order it sends each connection its player; killed it sends nothing" do
    pid = start("Rou")
    {:ok, %{handle: handle}} = Zone.MapInstance.enter(pid, player(self()))
    {:ok, %{handle: _other}} = Zone.MapInstance.enter(pid, player())
    :ok = GenServer.stop(pid, :shutdown)
    assert_receive {:cluster, {:map_stopped, %Zone.Player{handle: ^handle}}}, 1000
    refute_receive {:cluster, _}, 50

    pid = start("RouCos02")
    {:ok, %{handle: _handle}} = Zone.MapInstance.enter(pid, player(self()))

    TestLog.capture(fn ->
      Process.exit(pid, :kill)
      refute_receive {:cluster, _}, 100
    end)
  end

  test "after a restart of Zone.Maps a killed instance is still logged" do
    old_maps = Process.whereis(Zone.Maps)

    TestLog.capture(fn ->
      Process.exit(old_maps, :kill)
      wait_until(fn -> Process.whereis(Zone.Maps) not in [nil, old_maps] end)
      _ = :sys.get_state(Zone.Maps)
    end)

    {:ok, old} = Zone.MapInstance.whereis(0, "RouCos01")

    log =
      TestLog.capture(fn ->
        Process.exit(old, :kill)
        wait_for_new(old)
        _ = :sys.get_state(Zone.Maps)
      end)

    assert [_] = Regex.scan(~r/\[error\] Zone: map instance RouCos01 of world 0 crashed/, log)
  end

  test "five kills of one instance in a row leave the other instances running" do
    {:ok, other} = Zone.MapInstance.whereis(0, "Rou")

    TestLog.capture(fn ->
      for _ <- 1..5 do
        {:ok, old} = Zone.MapInstance.whereis(0, "RouCos01")
        Process.exit(old, :kill)
        wait_for_new(old)
      end

      _ = :sys.get_state(Zone.Maps)
    end)

    assert {:ok, ^other} = Zone.MapInstance.whereis(0, "Rou")
  end

  describe "movement" do
    alias Proto.Packets.ActMovefailAck
    alias Proto.Packets.ActReinforceStopCmd
    alias Proto.Packets.ActSomeonemoverunCmd
    alias Proto.Packets.ActSomeonemovewalkCmd
    alias Proto.Packets.ActSomeonestopCmd
    alias Proto.Packets.BriefinfoBriefinfodeleteCmd
    alias Proto.Packets.BriefinfoLogincharacterCmd

    # 64 x 512 bytes = 3200 x 3200 units; a lattice at x 1500 to 1699 (free only where both cell numbers are odd) and a
    # solid wall at x 2000 to 2199
    setup %{tmp_dir: tmp_dir} do
      blocked? = fn cx, cy ->
        (cx in 240..271 and not (rem(cx, 2) == 1 and rem(cy, 2) == 1)) or cx in 320..351
      end

      rows =
        for cy <- 0..511, byte <- 0..63, into: <<>> do
          <<Enum.sum(for i <- 0..7, blocked?.(byte * 8 + i, cy), do: Bitwise.bsl(1, i))>>
        end

      File.mkdir_p!(Path.join(tmp_dir, "BlockInfo"))
      File.write!(Path.join(tmp_dir, "BlockInfo/Rou.shbd"), <<64::little-32, 512::little-32>> <> rows)

      Application.put_env(:pinata, :clock_source, TestClock)
      TestClock.set(1_000_000)

      on_exit(fn ->
        Application.delete_env(:pinata, :clock_source)
        TestClock.reset()
      end)

      pid = start("Rou", tmp_dir)
      %{pid: pid, radius: :sys.get_state(pid).radius}
    end

    # a connection stub that forwards its packets tagged
    defp conn(tag) do
      test = self()

      spawn_link(fn ->
        relay = fn relay ->
          receive do
            {:cluster, {:packets, packets}} ->
              send(test, {tag, packets})
              relay.(relay)
          end
        end

        relay.(relay)
      end)
    end

    defp in_world!(pid, tag, {x, y}) do
      p = %{player(conn(tag)) | x: x, y: y, last_good: {x, y}}
      {:ok, %{handle: handle}} = Zone.MapInstance.enter(pid, p)
      {:ok, _} = Zone.MapInstance.login_complete(pid, handle)
      handle
    end

    # the packets of the stub since the last call, NPC appears left out
    defp got(pid, tag) do
      _ = :sys.get_state(pid)
      Process.sleep(20)
      collect(tag, [])
    end

    defp collect(tag, acc) do
      receive do
        {^tag, packets} -> collect(tag, acc ++ Enum.reject(packets, &npc?/1))
      after
        0 -> acc
      end
    end

    defp npc?(packet),
      do: match?(%Proto.Packets.BriefinfoRegenmobCmd{}, packet) or match?(%Proto.Packets.BriefinfoMobCmd{}, packet)

    defp clock(ms), do: TestClock.set(ms * 1000)

    defp two!(pid, pos \\ {1400, 1003}) do
      me = in_world!(pid, :me, pos)
      {x, y} = pos
      _observer = in_world!(pid, :obs, {x, y + 200})
      clock(5000)
      _ = got(pid, :me) ++ got(pid, :obs)
      me
    end

    defp at(pid, h) do
      {:ok, p} = Zone.MapInstance.player(pid, h)
      p
    end

    test "an accepted run goes to the players in sight, not to the mover", %{pid: pid} do
      me = two!(pid)
      assert :ok = Zone.MapInstance.move(pid, me, :run, {1400, 1003}, {1450, 1003})

      move = %ActSomeonemoverunCmd{
        handle: me,
        from_x: 1400,
        from_y: 1003,
        to_x: 1450,
        to_y: 1003,
        speed: 127,
        moveattr: 0
      }

      assert got(pid, :obs) == [move]
      assert got(pid, :me) == []
      assert %{dir: 45, mover: %Zone.Mover{duration: 393}} = at(pid, me)
      clock(5500)
      assert %{x: 1450, y: 1003, mover: :none, move: ^move} = at(pid, me)
    end

    test "an accepted walk relays 0x2018 at speed 33", %{pid: pid} do
      me = two!(pid)
      assert :ok = Zone.MapInstance.move(pid, me, :walk, {1400, 1003}, {1400, 1050})

      assert [%ActSomeonemovewalkCmd{from_x: 1400, from_y: 1003, to_x: 1400, to_y: 1050, speed: 33, moveattr: 0}] =
               got(pid, :obs)
    end

    test "from == to is refused with the server position; a running mover keeps running", %{pid: pid} do
      me = two!(pid)
      :ok = Zone.MapInstance.move(pid, me, :run, {1400, 1003}, {1450, 1003})
      _ = got(pid, :obs)
      :ok = Zone.MapInstance.move(pid, me, :run, {1420, 1003}, {1420, 1003})
      assert got(pid, :me) == [%ActMovefailAck{x: 1400, y: 1003}]
      assert got(pid, :obs) == []
      assert %{mover: %Zone.Mover{}} = at(pid, me)
    end

    test "from 200 units away is refused (dist² 40 001), 40 000 is accepted", %{pid: pid} do
      me = two!(pid)
      :ok = Zone.MapInstance.move(pid, me, :run, {1600, 1004}, {1450, 1003})
      assert got(pid, :me) == [%ActMovefailAck{x: 1400, y: 1003}]
      :ok = Zone.MapInstance.move(pid, me, :run, {1600, 1003}, {1450, 1003})
      assert got(pid, :me) == []
      assert [%ActSomeonemoverunCmd{}] = got(pid, :obs)
    end

    test "a target without a free cell is refused: inside the wall, outside the map", %{pid: pid} do
      me = two!(pid, {1900, 1003})
      :ok = Zone.MapInstance.move(pid, me, :run, {1900, 1003}, {2100, 1003})
      assert got(pid, :me) == [%ActMovefailAck{x: 1900, y: 1003}]
      :ok = Zone.MapInstance.move(pid, me, :run, {1900, 1003}, {4_000_000_000, 0})
      assert got(pid, :me) == [%ActMovefailAck{x: 1900, y: 1003}]
      assert got(pid, :obs) == []
    end

    test "a current position without a free cell is refused", %{pid: pid} do
      me = two!(pid, {1900, 1003})
      # the entry places a player off the wall, so put it there afterwards
      :sys.replace_state(pid, &update_in(&1.players[me], fn p -> %{p | x: 2100, last_good: {2100, 1003}} end))
      :ok = Zone.MapInstance.move(pid, me, :run, {2100, 1003}, {2300, 1003})
      assert got(pid, :me) == [%ActMovefailAck{x: 2100, y: 1003}]
    end

    test "a line through the wall is refused", %{pid: pid} do
      me = two!(pid, {1900, 1000})
      :ok = Zone.MapInstance.move(pid, me, :run, {1900, 1000}, {2300, 1000})
      assert got(pid, :me) == [%ActMovefailAck{x: 1900, y: 1000}]
      assert got(pid, :obs) == []
    end

    test "a stop in the middle of a slice stops at the millisecond", %{pid: pid} do
      me = two!(pid)
      :ok = Zone.MapInstance.move(pid, me, :run, {1400, 1003}, {1450, 1003})
      _ = got(pid, :obs)
      clock(5137)
      :ok = Zone.MapInstance.stop(pid, me, {1410, 1003})
      x = 1400 + div(50 * 137, 393)
      assert got(pid, :obs) == [%ActSomeonestopCmd{handle: me, x: x, y: 1003}]
      assert got(pid, :me) == []
      assert %{x: ^x, y: 1003, mover: :none, move: :none} = at(pid, me)
    end

    test "player/2 steps the mover to now, with no tick in between", %{pid: pid} do
      me = two!(pid)
      :ok = Zone.MapInstance.move(pid, me, :run, {1400, 1003}, {1450, 1003})
      clock(5050)
      x = 1400 + div(50 * 50, 393)
      assert %{x: ^x, y: 1003} = at(pid, me)
      assert x > 1400
    end

    test "a refused stop: 200 units away and inside the wall; the mover keeps running", %{pid: pid} do
      me = two!(pid, {1900, 1003})
      :ok = Zone.MapInstance.move(pid, me, :run, {1900, 1003}, {1950, 1003})
      _ = got(pid, :obs)
      :ok = Zone.MapInstance.stop(pid, me, {1900, 1204})
      assert got(pid, :me) == [%ActMovefailAck{x: 1900, y: 1003}]
      :ok = Zone.MapInstance.stop(pid, me, {2010, 1003})
      assert got(pid, :me) == [%ActMovefailAck{x: 1900, y: 1003}]
      assert got(pid, :obs) == []
      assert %{mover: %Zone.Mover{}} = at(pid, me)
    end

    test "a stop while standing relays 0x2013", %{pid: pid} do
      me = two!(pid)
      :ok = Zone.MapInstance.stop(pid, me, {1400, 1003})
      assert got(pid, :obs) == [%ActSomeonestopCmd{handle: me, x: 1400, y: 1003}]
    end

    test "a mover stuck in blocked cells is pulled back: 0x2013 to sight, 0x204A to the player", %{pid: pid} do
      me = two!(pid)
      :ok = Zone.MapInstance.move(pid, me, :run, {1400, 1003}, {1800, 1003})
      _ = got(pid, :obs)
      clock(8000)
      assert %{x: x, y: 1003, mover: :none, move: :none} = at(pid, me)
      assert x < 1500
      assert got(pid, :obs) == [%ActSomeonestopCmd{handle: me, x: x, y: 1003}]
      assert got(pid, :me) == [%ActReinforceStopCmd{x: x, y: 1003}]
    end

    test "a player that comes into sight on a step gets the appear at the position before the step", %{
      pid: pid,
      radius: r
    } do
      me = in_world!(pid, :me, {1400, 1003})
      far = in_world!(pid, :far, {1400, 1003 + r + 20})
      clock(5000)
      _ = got(pid, :me) ++ got(pid, :far)
      :ok = Zone.MapInstance.move(pid, me, :walk, {1400, 1003}, {1400, 1150})
      clock(6000)

      assert [%BriefinfoLogincharacterCmd{handle: ^me, x: 1400} = brief, %ActSomeonemovewalkCmd{} = m] = got(pid, :far)
      # the last position out of sight
      assert brief.y > 1003 and brief.y <= 1023
      assert {m.from_x, m.from_y, m.to_y} == {1400, brief.y, 1150}
      assert [%BriefinfoLogincharacterCmd{handle: ^far}] = got(pid, :me)
      # walking back out of sight: 0x1C0E both ways
      :ok = Zone.MapInstance.move(pid, me, :walk, {1400, 1036}, {1400, 1003})
      clock(7000)
      assert [_relay, %BriefinfoBriefinfodeleteCmd{handle: ^me}] = got(pid, :far)
      assert [%BriefinfoBriefinfodeleteCmd{handle: ^far}] = got(pid, :me)
    end

    test "an unknown handle and a mode-0 player", %{pid: pid} do
      assert {:error, :not_entered} = Zone.MapInstance.move(pid, 9000, :run, {1, 1}, {2, 2})
      assert {:error, :not_entered} = Zone.MapInstance.stop(pid, 9000, {1, 1})

      {:ok, %{handle: hidden}} =
        Zone.MapInstance.enter(pid, %{player(conn(:hidden)) | x: 1400, y: 1003, last_good: {1400, 1003}})

      assert :ok = Zone.MapInstance.move(pid, hidden, :run, {1400, 1003}, {1400, 1003})
      assert :ok = Zone.MapInstance.stop(pid, hidden, {1400, 1003})
      assert got(pid, :hidden) == []
      assert %{mover: :none, move: :none} = at(pid, hidden)
    end

    test "an emote goes to the player and the players in sight and stays until an accepted move", %{pid: pid} do
      alias Proto.Packets.ActSomeoneemoticonCmd
      me = two!(pid)
      assert :ok = Zone.MapInstance.action(pid, me, {:emote, 7})
      assert got(pid, :me) == [%ActSomeoneemoticonCmd{handle: me, emoticon_id: 7}]
      assert got(pid, :obs) == [%ActSomeoneemoticonCmd{handle: me, emoticon_id: 7}]
      assert %{emoticon: {7, 0}} = at(pid, me)
      # a stop and a refused move keep it
      :ok = Zone.MapInstance.stop(pid, me, {1400, 1003})
      :ok = Zone.MapInstance.move(pid, me, :run, {1420, 1003}, {1420, 1003})
      assert %{emoticon: {7, 0}} = at(pid, me)
      :ok = Zone.MapInstance.move(pid, me, :run, {1400, 1003}, {1450, 1003})
      assert %{emoticon: {0xFF, 0xFFFF}} = at(pid, me)
    end

    test "an emote stop goes to both and keeps the frame", %{pid: pid} do
      alias Proto.Packets.ActSomeoneemoticonstopCmd
      me = two!(pid)
      assert :ok = Zone.MapInstance.action(pid, me, {:emote_stop, 23, 300})
      packet = %ActSomeoneemoticonstopCmd{handle: me, emoticon_id: 23, emoticon_frame: 300}
      assert got(pid, :me) == [packet]
      assert got(pid, :obs) == [packet]
      assert %{emoticon: {23, 300}} = at(pid, me)
    end

    test "a jump and a stance change go to the players in sight only and clear the emote", %{pid: pid} do
      alias Proto.Packets.ActSomeeonejumpCmd
      alias Proto.Packets.ActSomeonechangemodeCmd
      me = two!(pid)
      :ok = Zone.MapInstance.action(pid, me, {:emote, 7})
      _ = got(pid, :me) ++ got(pid, :obs)
      assert :ok = Zone.MapInstance.action(pid, me, :jump)
      assert got(pid, :obs) == [%ActSomeeonejumpCmd{handle: me}]
      assert got(pid, :me) == []
      assert %{emoticon: {0xFF, 0xFFFF}} = at(pid, me)
      :ok = Zone.MapInstance.action(pid, me, {:emote, 7})
      _ = got(pid, :me) ++ got(pid, :obs)
      assert :ok = Zone.MapInstance.action(pid, me, {:stance, 2})
      assert got(pid, :obs) == [%ActSomeonechangemodeCmd{handle: me, mode: 2}]
      assert got(pid, :me) == []
      assert %{stance: 2, emoticon: {0xFF, 0xFFFF}} = at(pid, me)
    end

    test "the entrant's appear carries {0xFF, 0}, then login_complete clears the emote state", %{pid: pid} do
      first = in_world!(pid, :me, {1400, 1003})
      assert %{emoticon: {0xFF, 0xFFFF}} = at(pid, first)
      _ = got(pid, :me)

      {:ok, %{handle: second}} =
        Zone.MapInstance.enter(pid, %{player(conn(:obs)) | x: 1400, y: 1203, last_good: {1400, 1203}})

      {:ok, burst} = Zone.MapInstance.login_complete(pid, second)
      assert [%BriefinfoLogincharacterCmd{handle: ^second, emoticon_id: 0xFF, emoticon_frame: 0}] = got(pid, :me)
      chars = for %Proto.Packets.BriefinfoCharacterCmd{chars: chars} <- burst, c <- chars, do: c
      seen = for %BriefinfoLogincharacterCmd{handle: ^first} = b <- chars, do: b
      assert [%{emoticon_id: 0xFF, emoticon_frame: 0xFFFF}] = seen

      assert %{emoticon: {0xFF, 0xFFFF}} = at(pid, second)
    end

    test "actions of an unknown handle and a mode-0 player", %{pid: pid} do
      assert {:error, :not_entered} = Zone.MapInstance.action(pid, 9000, :jump)

      {:ok, %{handle: hidden}} =
        Zone.MapInstance.enter(pid, %{player(conn(:hidden)) | x: 1400, y: 1003, last_good: {1400, 1003}})

      _obs = in_world!(pid, :obs, {1400, 1203})
      _ = got(pid, :obs)

      for action <- [{:emote, 7}, {:emote_stop, 7, 1}, :jump, {:stance, 2}],
          do: assert(:ok = Zone.MapInstance.action(pid, hidden, action))

      assert got(pid, :hidden) == [] and got(pid, :obs) == []
      assert %{stance: 1, emoticon: {0xFF, 0}} = at(pid, hidden)
    end

    # 512 x 512 cells of the setup's size, blocked where the function says
    defp blocks(blocked?) do
      bits =
        for cy <- 0..511, byte <- 0..63, into: <<>> do
          <<Enum.sum(for i <- 0..7, blocked?.(byte * 8 + i, cy), do: Bitwise.bsl(1, i))>>
        end

      %GameData.BlockData{bytes_per_row: 64, rows: 512, bits: bits}
    end

    defp set_blocks(pid, b, regen), do: :sys.replace_state(pid, &%{&1 | block_data: b, regen: regen})

    test "enter/2 on a blocked cell places the player on a free neighbour", %{pid: pid} do
      p = %{player() | x: 2001, y: 1003, last_good: {2001, 1003}}
      assert {:ok, %Zone.Player{x: x, y: y, last_good: {x, y}} = entered} = Zone.MapInstance.enter(pid, p)
      refute GameData.BlockData.blocked?(:sys.get_state(pid).block_data, x, y)
      assert {x, y} != {2001, 1003} and abs(x - 2001) <= 25 and abs(y - 1003) <= 21
      assert {:ok, ^entered} = Zone.MapInstance.player(pid, entered.handle)
    end

    test "enter/2 on a fully blocked map is refused with :no_free_cell", %{pid: pid} do
      set_blocks(pid, blocks(fn _, _ -> true end), {100, 100})
      assert {:error, :no_free_cell} = Zone.MapInstance.enter(pid, player())
      assert :sys.get_state(pid).players == %{}
    end

    test "relocate/3: a blocked point is placed; no free cell anywhere refuses and sends nothing", %{pid: pid} do
      me = in_world!(pid, :me, {1400, 1003})
      _obs = in_world!(pid, :obs, {1400, 1203})
      _ = got(pid, :obs)
      assert {:ok, %Zone.Player{x: x, y: y}} = Zone.MapInstance.relocate(pid, me, {2001, 1003})
      refute GameData.BlockData.blocked?(:sys.get_state(pid).block_data, x, y)
      _ = got(pid, :obs)

      before = at(pid, me)
      set_blocks(pid, blocks(fn _, _ -> true end), {100, 100})
      assert {:error, :no_free_cell} = Zone.MapInstance.relocate(pid, me, {1400, 1003})
      assert at(pid, me) == before
      assert got(pid, :obs) == []
    end

    test "with no free cell in reach the player is placed at the regen point, with an info line", %{pid: pid} do
      set_blocks(pid, blocks(&(not (&1 == 16 and &2 == 16))), {100, 100})
      p = %{player() | x: 1600, y: 1600, last_good: {1600, 1600}}

      log =
        TestLog.capture(fn -> assert {:ok, %Zone.Player{x: 100, y: 100}} = Zone.MapInstance.enter(pid, p) end)

      assert log =~ "[info] Zone: map Rou: no free cell around (1600, 1600), placed at the regen point"
    end
  end
end
