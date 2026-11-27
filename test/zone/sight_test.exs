defmodule Zone.SightTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.BriefinfoBriefinfodeleteCmd, as: Delete
  alias Proto.Packets.BriefinfoCharacterCmd
  alias Proto.Packets.BriefinfoLogincharacterCmd
  alias Proto.Packets.BriefinfoMobCmd
  alias Proto.Packets.BriefinfoRegenmobCmd
  alias Proto.Packets.MapLogoutCmd
  alias Zone.Sight

  @table [
    [1, 1, 1, 1, 0, 1],
    [0, 0, 0, 1, 0, 1],
    [0, 0, 0, 1, 1, 1],
    [0, 0, 0, 0, 1, 1],
    [0, 0, 0, 0, 0, 0],
    [1, 0, 0, 0, 1, 1]
  ]

  defp player(handle, x, y, fields \\ %{}) do
    character = %{
      id: 1,
      slot: 0,
      name: "P#{handle}",
      level: 1,
      exp: 0,
      login_map: "Rou",
      login_x: x,
      login_y: y,
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

    struct!(
      %Zone.Player{
        character: character,
        world_no: 0,
        map: "Rou",
        x: x,
        y: y,
        walk_speed: 33,
        run_speed: 127,
        map_type: 0,
        equipment: [],
        address: "127.0.0.1",
        last_good: {x, y},
        handle: handle,
        mode: 1
      },
      fields
    )
  end

  defp npc(handle, x, y) do
    row = %GameData.ShineNpc{
      mob_name: "N",
      map: "Rou",
      x: x,
      y: y,
      direct: 0,
      npc_menu: 0,
      role: "QuestNpc",
      role_arg: ""
    }

    brief = %BriefinfoRegenmobCmd{
      handle: handle,
      mode: 2,
      mob_id: 1,
      x: x,
      y: y,
      dir: 0,
      flagstate: 0,
      flag: <<0::792>>,
      animation: "",
      animation_level: 0,
      kq_team_type: 2,
      regen_ani: 0
    }

    %Zone.Npc{handle: handle, row: row, x: x, y: y, brief: brief}
  end

  defp view(objects, radius \\ 1000) do
    grid = Enum.reduce(objects, Zone.Grid.new(max(radius, 1)), &Zone.Grid.put(&2, &1.handle, {&1.x, &1.y}))

    %{
      radius: radius,
      grid: grid,
      players: for(%Zone.Player{} = p <- objects, into: %{}, do: {p.handle, p}),
      npcs: for(%Zone.Npc{} = n <- objects, into: %{}, do: {n.handle, n})
    }
  end

  defp deliveries(list), do: for({p, packets} <- list, do: {p.handle, packets})

  test "packet sizes" do
    assert BriefinfoLogincharacterCmd.__packet__().size == 235
    assert BriefinfoRegenmobCmd.__packet__().size == 149
  end

  test "brief/1 equals the captured 0x1C06 of X14B with the abstates zeroed" do
    transcript =
      "../replay/transcripts/26_11_15_14_second-client-in-sight.txt"
      |> Path.expand(__DIR__)
      |> Replay.Transcript.read!()

    %{payload: payload} =
      Enum.find(transcript.packets, &(&1.opcode == 0x1C06 and &1.dir == :server and &1.payload =~ "X14B"))

    {:ok, c} = BriefinfoLogincharacterCmd.decode(payload)
    assert BriefinfoLogincharacterCmd.encode(c) == payload

    p =
      player(c.handle, c.x, c.y, %{
        dir: c.dir,
        # X14B was in the world before: its emote state is cleared (capture 45 index 888)
        emoticon: {0xFF, 0xFFFF},
        equipment: [%{slot: 12, item_id: Enum.at(c.equip, 2), upgrade: 0, class: 5}]
      })

    p = %{
      p
      | character: %{
          p.character
          | name: c.name,
            class: c.chrclass,
            gender: c.gender,
            race: c.race,
            hair: c.hairtype,
            hair_color: c.haircolor,
            face: c.faceshape,
            level: c.level
        }
    }

    <<before::binary-91, _abstates::binary-99, rest::binary>> = payload
    assert BriefinfoLogincharacterCmd.encode(Sight.brief(p)) == before <> <<0::792>> <> rest
  end

  test "sees?/2: the sub-layer table one way, and dimensions" do
    for {row, shown} <- Enum.with_index(@table), {cell, viewer} <- Enum.with_index(row) do
      assert Sight.sees?(player(1, 0, 0, %{sub_layer: viewer}), player(2, 0, 0, %{sub_layer: shown})) == (cell == 1)
    end

    sees? = fn a, b -> Sight.sees?(player(1, 0, 0, %{dimension: a}), player(2, 0, 0, %{dimension: b})) end
    assert sees?.(0, 0)
    refute sees?.(0, 1)
    assert sees?.(-1, 5)
    assert sees?.(1, -1)
  end

  test "crowd_radius/2" do
    assert Sight.crowd_radius(28, 1600) == 1600
    assert Sight.crowd_radius(28, 2000) == 2000
    assert Sight.crowd_radius(29, 2000) == 1600
    assert Sight.crowd_radius(30, 1600) == 1581
    assert Sight.crowd_radius(528, 1600) == 376
    assert Sight.crowd_radius(5000, 1600) == 376
  end

  describe "step/3" do
    test "appear both ways when crossing into the radius, nothing while staying inside, 0x1C0E when leaving" do
      a = player(8000, 5000, 5000)
      b = player(8001, 6500, 5000)
      v = view([a, b])
      moved = %{a | x: 5600}

      # the mover's appear carries its position before the step (capture 45)
      assert deliveries(Sight.step(v, a, {5600, 5000})) == [
               {8001, [Sight.brief(a)]},
               {8000, [Sight.brief(b)]}
             ]

      assert Sight.step(view([moved, b]), moved, {5650, 5000}) == []

      assert deliveries(Sight.step(view([moved, b]), moved, {5000, 5000})) == [
               {8001, [%Delete{handle: 8000}]},
               {8000, [%Delete{handle: 8001}]}
             ]
    end

    test "appears go out before disappears" do
      a = player(8000, 5000, 5000)
      b = player(8001, 6500, 5000)
      c = player(8002, 4400, 5000)

      assert [
               {8001, [%BriefinfoLogincharacterCmd{handle: 8000}]},
               {8000, [%BriefinfoLogincharacterCmd{handle: 8001}]},
               {8002, [%Delete{handle: 8000}]},
               {8000, [%Delete{handle: 8002}]}
             ] = deliveries(Sight.step(view([a, b, c]), a, {5600, 5000}))
    end

    test "an NPC appears to the mover and is never deleted" do
      a = player(8000, 5000, 5000)
      n = npc(17_084, 6500, 5000)
      assert deliveries(Sight.step(view([a, n]), a, {5600, 5000})) == [{8000, [n.brief]}]
      moved = %{a | x: 5600}
      assert Sight.step(view([moved, n]), moved, {5000, 5000}) == []
    end

    test "a mode-0 player gets and causes nothing" do
      a = player(8000, 5000, 5000)
      b = player(8001, 6500, 5000, %{mode: 0})
      assert Sight.step(view([a, b]), a, {5600, 5000}) == []
      assert Sight.step(view([%{a | mode: 0}, %{b | mode: 1}]), %{a | mode: 0}, {5600, 5000}) == []
    end

    test "the appear of a moving player is its 0x1C06 and its move packet from the position before the step" do
      move = %Proto.Packets.ActSomeonemoverunCmd{
        handle: 8000,
        from_x: 4000,
        from_y: 5000,
        to_x: 6000,
        to_y: 5000,
        speed: 127,
        moveattr: 0
      }

      a = player(8000, 5000, 5000, %{move: move})
      b = player(8001, 6500, 5000)

      resent = %{move | from_x: 5000}

      assert [{8001, [%BriefinfoLogincharacterCmd{x: 5000}, ^resent]}, {8000, [_]}] =
               deliveries(Sight.step(view([a, b]), a, {5600, 5000}))

      assert Sight.appear(a) == [Sight.brief(a), %{move | from_x: 5000}]
      assert Sight.inform(view([a, b]), %{b | x: 5100}, 8000) == [Sight.brief(a), %{move | from_x: 5000}]
    end

    test "a hidden mover (sub-layer 3) gets the other's appear, the other gets nothing" do
      a = player(8000, 5000, 5000, %{sub_layer: 3})
      b = player(8001, 6500, 5000)
      assert deliveries(Sight.step(view([a, b]), a, {5600, 5000})) == [{8000, [Sight.brief(b)]}]
    end

    test "different dimensions: nothing at all" do
      a = player(8000, 5000, 5000)
      b = player(8001, 6500, 5000, %{dimension: 1})
      assert Sight.step(view([a, b]), a, {5600, 5000}) == []
      moved = %{a | x: 5600}
      assert Sight.step(view([moved, b]), moved, {5000, 5000}) == []
    end
  end

  describe "entry/2 and inform/3" do
    test "29 NPCs go out in two 0x1C09 of 28 and 1, without a distance limit" do
      a = player(8000, 5000, 5000)
      npcs = for i <- 0..28, do: npc(17_084 + i, 100 + i * 300, 100)

      assert {[%BriefinfoMobCmd{mobs: first}, %BriefinfoMobCmd{mobs: [_]}], []} =
               Sight.entry(view([a | npcs]), a)

      assert length(first) == 28
    end

    test "a player at exactly the radius is in the exchange; inform at exactly the radius is not" do
      a = player(8000, 5000, 5000)
      b = player(8001, 6000, 5000)
      v = view([a, b])

      assert {[%BriefinfoCharacterCmd{chars: [%{handle: 8001}]}], [{%{handle: 8001}, [%{handle: 8000}]}]} =
               Sight.entry(v, a)

      assert Sight.inform(v, a, 8001) == []
      assert Sight.inform(view([a, %{b | x: 5999}]), a, 8001) == [Sight.brief(%{b | x: 5999})]
      assert Sight.inform(v, a, 8000) == []
      assert Sight.inform(v, a, 9000) == []
    end
  end

  describe "dimension/3" do
    test "0 to 5: 0x1805 to the player, the GM gets the 0x1C0E of the player and of each NPC" do
      gm = player(8000, 5000, 5000)
      b = player(8001, 5500, 5000)
      n1 = npc(17_084, 5100, 5000)
      n2 = npc(17_085, 9000, 9000)

      assert deliveries(Sight.dimension(view([gm, b, n1, n2]), gm, 5)) == [
               {8001, [%MapLogoutCmd{handle: 8000}]},
               {8000, [%Delete{handle: 8001}, %Delete{handle: 17_084}, %Delete{handle: 17_085}]}
             ]
    end

    test "5 to 0: the GM gets the appears of the player and of each NPC, the player the GM's appear" do
      gm = player(8000, 5000, 5000, %{dimension: 5})
      b = player(8001, 5500, 5000)
      n1 = npc(17_084, 5100, 5000)
      n2 = npc(17_085, 9000, 9000)

      assert deliveries(Sight.dimension(view([gm, b, n1, n2]), gm, 0)) == [
               {8000, Sight.appear(b) ++ Sight.appear(n1) ++ Sight.appear(n2)},
               {8001, Sight.appear(%{gm | dimension: 0})}
             ]
    end

    test "a player already in the new dimension: appears both ways, after the GM's deletes" do
      gm = player(8000, 5000, 5000)
      b = player(8001, 5500, 5000)
      c = player(8002, 5000, 5500, %{dimension: 5})

      assert deliveries(Sight.dimension(view([gm, b, c]), gm, 5)) == [
               {8001, [%MapLogoutCmd{handle: 8000}]},
               {8000, [%Delete{handle: 8001} | Sight.appear(c)]},
               {8002, Sight.appear(%{gm | dimension: 5})}
             ]
    end

    test "the same number: 0x1805 and then the GM's appear to the player, nothing to the GM" do
      gm = player(8000, 5000, 5000)
      b = player(8001, 5500, 5000)

      assert deliveries(Sight.dimension(view([gm, b, npc(17_084, 5100, 5000)]), gm, 0)) == [
               {8001, [%MapLogoutCmd{handle: 8000}]},
               {8001, Sight.appear(gm)}
             ]
    end

    test "0 to -1: the GM only gains, every player in sight gets its appear" do
      gm = player(8000, 5000, 5000)
      b0 = player(8001, 5500, 5000)
      b1 = player(8002, 5000, 5500, %{dimension: 1})
      gm2 = %{gm | dimension: -1}

      d = deliveries(Sight.dimension(view([gm, b0, b1, npc(17_084, 5100, 5000)]), gm, -1))

      assert [{8001, [%MapLogoutCmd{handle: 8000}]}, {8000, own} | shown] = d
      assert own == Sight.appear(b1)
      assert Enum.sort(shown) == [{8001, Sight.appear(gm2)}, {8002, Sight.appear(gm2)}]
    end

    test "a hidden GM: nobody else gets anything, the GM still gets its deletes" do
      gm = player(8000, 5000, 5000, %{sub_layer: 3})
      b = player(8001, 5500, 5000)
      c = player(8002, 5000, 5500, %{dimension: 5})

      assert deliveries(Sight.dimension(view([gm, b, c]), gm, 5)) == [
               {8000, [%Delete{handle: 8001} | Sight.appear(c)]}
             ]
    end

    test "mode 0 gives nothing; a player outside the radius is left out, an NPC outside it is not" do
      gm = player(8000, 5000, 5000)
      far = player(8001, 7000, 5000)
      n = npc(17_084, 9000, 9000)
      v = view([gm, far, n])

      assert Sight.dimension(v, %{gm | mode: 0}, 5) == []
      assert deliveries(Sight.dimension(v, gm, 5)) == [{8000, [%Delete{handle: 17_084}]}]
    end
  end
end
