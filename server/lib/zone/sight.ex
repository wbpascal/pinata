defmodule Zone.Sight do
  @moduledoc """
  The sight rules of a map instance as pure functions (`docs/technical/sight.md`): who sees whom, the entry
  exchange, the appear and disappear packets of a step, the receivers of a broadcast and the answer to `0x1C01`.

  An object is in sight of another when `dist² < Sight²` (`MapInfo.Sight`, the radius of the view), both are in the
  same dimension or one of them in -1, and the sub-layer table lets the one be shown to the other (`sees?/2`).
  Nothing here keeps a "seen" list: a step computes appears and disappears from the old and the new position.

  A delivery `{player, packets}` is a list of packets for the connection of one player, in order.
  """

  alias Proto.Packets.BriefinfoBriefinfodeleteCmd
  alias Proto.Packets.BriefinfoCharacterCmd
  alias Proto.Packets.BriefinfoLogincharacterCmd
  alias Proto.Packets.BriefinfoMobCmd
  alias Zone.Grid

  @type object :: Zone.Player.t() | Zone.Npc.t()
  @type view :: %{
          radius: non_neg_integer(),
          grid: Grid.t(),
          npcs: %{non_neg_integer() => Zone.Npc.t()},
          players: %{non_neg_integer() => Zone.Player.t()}
        }
  @type delivery :: {Zone.Player.t(), [struct()]}

  # SendMyBrief of Files/Server/2016/9Data/Shine/World/SubLayerInteract.txt (sublayerview.sli_Interactive,
  # DAT_0d67a118): row = the sub-layer of the object shown, column = the sub-layer of the receiver; 1 = shown.
  # 0 Base, 1 RangerStealth, 2 Observer, 3 AdminHide, 4 GMDoor, 5 GMPlayer.
  @sub_layers {
    {1, 1, 1, 1, 0, 1},
    {0, 0, 0, 1, 0, 1},
    {0, 0, 0, 1, 1, 1},
    {0, 0, 0, 0, 1, 1},
    {0, 0, 0, 0, 0, 0},
    {1, 0, 0, 0, 1, 1}
  }

  # the order of WorldManager.Avatar (Equ_Head to Equ_AccShield), which Zone may not reference
  @equip_slots [1, 24, 12, 7, 10, 19, 21, 22, 20, 8, 27, 28, 26, 11, 13, 9, 17, 18, 25, 29]

  # the crowd figure counts the objects within 500 units; 29 or more shrink the radius (cbd_DistanceSquar @ FUN_0043e740)
  @crowd_range 500
  @crowd_min 29
  @batch 28

  @doc """
  Whether the viewer is shown the other object: the same dimension or one of them in -1, and the sub-layer table.
  One way; each direction is tested on its own. P02-B27 fixed: objects in different dimensions are not in sight.
  """
  @spec sees?(object(), object()) :: boolean()
  def sees?(viewer, shown) do
    same_dimension = viewer.dimension == shown.dimension or viewer.dimension == -1 or shown.dimension == -1
    same_dimension and @sub_layers |> elem(shown.sub_layer) |> elem(viewer.sub_layer) == 1
  end

  @doc """
  The radius of the entry exchange for `n` objects within 500 units of the entrant (`cbd_DistanceSquar` @
  FUN_0043e740): below 29 the map's radius, from 29 on `√(75,000,000 / n)` with `n` at most 528, at most 1600.
  """
  @spec crowd_radius(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def crowd_radius(n, radius) when n < @crowd_min, do: radius
  def crowd_radius(n, _radius), do: min(1600, trunc(:math.sqrt(75_000_000 / min(n, 528))))

  @doc """
  The appear packet `0x1C06` of a player (no move, no abstates, no title, no guild). Its `mode` is 0 before `0x1803`,
  else the stance; it carries the emote state (`Zone.Player`, `docs/technical/flows/actions.md`).
  """
  @spec brief(Zone.Player.t()) :: BriefinfoLogincharacterCmd.t()
  def brief(%Zone.Player{character: c} = p) do
    worn = Map.new(p.equipment, &{&1.slot, &1})
    {emoticon_id, emoticon_frame} = p.emoticon

    %BriefinfoLogincharacterCmd{
      handle: p.handle,
      name: c.name,
      x: p.x,
      y: p.y,
      dir: p.dir,
      mode: if(p.mode == 0, do: 0, else: p.stance),
      chrclass: c.class,
      gender: c.gender,
      shape_class: c.class,
      race: c.race,
      hairtype: c.hair,
      haircolor: c.hair_color,
      faceshape: c.face,
      equip: for(slot <- @equip_slots, do: item_id(worn, slot)),
      upgrade_righthand: upgrade(worn, 12),
      upgrade_lefthand: upgrade(worn, 10),
      upgrade_leg: upgrade(worn, 19),
      upgrade_body: upgrade(worn, 7),
      upgrade_unused: 0,
      upgrade_shoes: upgrade(worn, 21),
      shapedata_rest: <<0, 0>>,
      polymorph: 0xFFFF,
      emoticon_id: emoticon_id,
      emoticon_frame: emoticon_frame,
      title_type: 0,
      title_element: 0,
      title_mob_id: 0,
      abstatebit: <<0::792>>,
      myguild: 0,
      type: 2,
      is_guild_academy_member: 0,
      is_auto_pick: 0,
      level: c.level,
      animation: "",
      mover_handle: 0xFFFF,
      mover_slot: 0x0A,
      kq_team_type: 2,
      is_use_item_minimon: 0
    }
  end

  defp item_id(worn, slot) do
    case worn do
      %{^slot => %{item_id: id}} -> id
      %{} -> 0xFFFF
    end
  end

  defp upgrade(worn, slot) do
    case worn do
      %{^slot => %{upgrade: u}} -> Bitwise.band(u, 0xF)
      %{} -> 0
    end
  end

  @doc """
  The packets that make an object appear to a receiver: a player's `0x1C06`, followed by its remembered move packet
  with `from` = its current position (`ResendLastMove` FUN_005555e0); an NPC's appear element.
  """
  @spec appear(object()) :: [struct()]
  def appear(%Zone.Player{move: :none} = player), do: [brief(player)]
  def appear(%Zone.Player{move: move} = player), do: [brief(player), %{move | from_x: player.x, from_y: player.y}]
  def appear(%Zone.Npc{brief: brief}), do: [brief]

  @doc """
  The entry exchange of a player that has just turned to mode 1 (`so_ExchageBriefInfo` @ FUN_00441460): the
  packets for the entrant (`0x1C07` batches of the players in sight and `0x1C09` batches of the NPCs, at most 28
  each: a full batch goes out during the walk, then the rest of the players, then the rest of the NPCs) and one delivery of its appear packet to every player that sees it. Players count at the crowd-shrunk
  radius with `dist² <= r²`; NPCs count without a distance limit (capture `idle_in_world`).
  """
  @spec entry(view(), Zone.Player.t()) :: {[struct()], [delivery()]}
  def entry(view, %Zone.Player{handle: handle} = entrant) do
    pos = {entrant.x, entrant.y}
    r = view.grid |> Grid.query(pos, @crowd_range, handle) |> length() |> crowd_radius(view.radius)

    players =
      for h <- Grid.query(view.grid, pos, r + 1, handle),
          %Zone.Player{mode: 1} = o <- [Map.get(view.players, h)],
          dist2(o, pos) <= r * r,
          do: {h, {o.x, o.y}}

    npcs = for {h, npc} <- view.npcs, do: {h, {npc.x, npc.y}}

    {out, chars, mobs, deliveries} =
      players
      |> Kernel.++(npcs)
      |> Grid.walk_order(pos, handle)
      |> Enum.reduce({[], [], [], []}, fn h, acc -> exchange(view, entrant, h, acc) end)

    out = out |> flush(:chars, chars) |> flush(:mobs, mobs)
    {Enum.reverse(out), Enum.reverse(deliveries)}
  end

  defp exchange(view, entrant, h, {out, chars, mobs, deliveries}) do
    case view do
      %{npcs: %{^h => npc}} ->
        if sees?(entrant, npc) do
          {out, mobs} = add(out, :mobs, mobs, npc.brief)
          {out, chars, mobs, deliveries}
        else
          {out, chars, mobs, deliveries}
        end

      %{players: %{^h => other}} ->
        deliveries = if sees?(other, entrant), do: [{other, appear(entrant)} | deliveries], else: deliveries

        if sees?(entrant, other) do
          {out, chars} = add(out, :chars, chars, brief(other))
          {out, chars, mobs, deliveries}
        else
          {out, chars, mobs, deliveries}
        end
    end
  end

  # a batch that holds 28 goes out before the 29th is added (bixc_Exchange @ FUN_0043fd00, bixm_Exchange @ FUN_0043fe40)
  defp add(out, kind, batch, element) when length(batch) == @batch, do: {flush(out, kind, batch), [element]}
  defp add(out, _kind, batch, element), do: {out, [element | batch]}

  defp flush(out, _kind, []), do: out
  defp flush(out, :chars, batch), do: [%BriefinfoCharacterCmd{chars: Enum.reverse(batch)} | out]
  defp flush(out, :mobs, batch), do: [%BriefinfoMobCmd{mobs: Enum.reverse(batch)} | out]

  @doc """
  The deliveries of one step of a player from its position in `player` to `new`: first the appears of the objects
  that come into sight (both ways; an NPC only to the mover), then the `0x1C0E` of the players that leave it (both
  ways; NPCs are never removed). The mover's own appear carries its position before the step (capture 45: the
  original sends it before it sets the position). A player in mode 0 causes nothing.
  """
  @spec step(view(), Zone.Player.t(), Grid.point()) :: [delivery()]
  def step(_view, %Zone.Player{mode: 0}, _new), do: []

  def step(view, %Zone.Player{handle: handle} = mover, new) do
    old = {mover.x, mover.y}
    r2 = view.radius * view.radius

    appears =
      for h <- Grid.query(view.grid, new, view.radius, handle),
          o <- shown(view, h),
          dist2(o, old) >= r2,
          d <- appear_both(mover, o),
          do: d

    disappears =
      for h <- Grid.query(view.grid, old, view.radius, handle),
          %Zone.Player{mode: 1} = o <- [Map.get(view.players, h)],
          dist2(o, new) >= r2,
          d <- disappear_both(mover, o),
          do: d

    appears ++ disappears
  end

  defp appear_both(mover, %Zone.Player{} = o) do
    if(sees?(o, mover), do: [{o, appear(mover)}], else: []) ++
      if sees?(mover, o), do: [{mover, appear(o)}], else: []
  end

  defp appear_both(mover, %Zone.Npc{} = o), do: if(sees?(mover, o), do: [{mover, appear(o)}], else: [])

  defp disappear_both(mover, o) do
    if(sees?(o, mover), do: [{o, [%BriefinfoBriefinfodeleteCmd{handle: mover.handle}]}], else: []) ++
      if sees?(mover, o), do: [{mover, [%BriefinfoBriefinfodeleteCmd{handle: o.handle}]}], else: []
  end

  @doc "The players that receive what the sender does: mode 1, in sight at the full radius and shown the sender."
  @spec receivers(view(), Zone.Player.t()) :: [Zone.Player.t()]
  def receivers(_view, %Zone.Player{mode: 0}), do: []

  def receivers(view, %Zone.Player{handle: handle} = sender) do
    for h <- Grid.query(view.grid, {sender.x, sender.y}, view.radius, handle),
        %Zone.Player{mode: 1} = o <- [Map.get(view.players, h)],
        sees?(o, sender),
        do: o
  end

  @doc """
  The answer to `0x1C01`: the appear packets of the object when the requester (mode 1) sees it and it is in sight
  (`dist² < Sight²`), else nothing. The in-sight check is the fix decided in issue 90; Z02-B3 is not reachable
  without abstates.
  """
  @spec inform(view(), Zone.Player.t(), non_neg_integer()) :: [struct()]
  def inform(_view, %Zone.Player{mode: 0}, _handle), do: []
  def inform(_view, %Zone.Player{handle: handle}, handle), do: []

  def inform(view, %Zone.Player{} = requester, handle) do
    case shown(view, handle) do
      [target] ->
        if dist2(target, {requester.x, requester.y}) < view.radius * view.radius and sees?(requester, target),
          do: appear(target),
          else: []

      [] ->
        []
    end
  end

  # the object of a handle as a list of zero or one, when it is shown: a player in mode 1 or an NPC with a MobInfo row
  defp shown(view, h) do
    case view do
      %{players: %{^h => %Zone.Player{mode: 1} = p}} -> [p]
      %{npcs: %{^h => %Zone.Npc{brief: %{}} = npc}} -> [npc]
      %{} -> []
    end
  end

  defp dist2(%{x: x, y: y}, {px, py}), do: (x - px) * (x - px) + (y - py) * (y - py)
end
