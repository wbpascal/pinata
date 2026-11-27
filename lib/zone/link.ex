defmodule Zone.Link do
  @moduledoc """
  The map change of a Zone connection (flow: `docs/technical/flows/map-change.md`): the destination of a Gate NPC
  (`LinkTable`) or of a town portal (`TownPortal.shn`), the confirmation menu `0x3C01` of a gate, and `run/5`, the
  steps of the change itself.

  `run/5` asks WorldManager for the Zone node of the target map (`Cluster.WorldManager.zone_of/2`), saves the
  player, removes it from the map instance and parks it in the session as the reservation
  (`Cluster.Sessions.reserve/2`); the answer is `0x180A` with the node's address and the session handle. A target on
  the player's own map instance saves, moves the player inside the instance (`Zone.MapInstance.relocate/3`) and
  answers `0x1809`. A target on another map instance of this node whose `FieldList` machine number is the one of the
  player's map (the original's "same zone", Z01 §7.1) saves (`:auto`), enters the player into the target instance
  under its handle (`Zone.MapInstance.enter/3`), removes it from the old one (`0x1805` to the players in sight) and
  answers `0x1809` on the same connection; a handle in use on the target, or any other failure before the save,
  falls back to the reconnect. The first failing step is the result and nothing after it runs. The map instance
  places the arriving player on a free cell (`Zone.Placement`); `0x1809` carries the placed point, and no free cell
  refuses the change with `:no_free_cell`.

  The GM command `&linkto` (flow: `docs/technical/flows/gm-commands.md`) enters through the same path:
  `Zone.Handler.perform/1` with `{:link, :gm, map, player, entered_at, session, dest}`.
  """

  alias Proto.Packets.MapLinkotherCmd
  alias Proto.Packets.MapLinksameCmd
  alias Proto.Packets.MenuServermenuReq
  alias Proto.Packets.ServerMenu

  @type dest :: %{map: binary(), map_client: binary(), x: non_neg_integer(), y: non_neg_integer()}
  @type refusal ::
          :no_map_info | :not_running | :not_on_map | :no_free_cell | {:save, :not_found | :database} | :no_session

  @doc "The destination of a Gate NPC: the first `LinkTable` row of its argument with a valid position."
  @spec gate(Zone.Npc.t()) :: {:ok, dest()} | {:error, :no_role | :no_link}
  def gate(%Zone.Npc{row: %{role: "Gate", role_arg: arg}}) do
    case Enum.find(GameData.lookup(GameData.LinkTable, :argument, arg), &(&1.x >= 0 and &1.y >= 0)) do
      nil -> {:error, :no_link}
      link -> {:ok, %{map: link.map_server, map_client: link.map_client, x: link.x, y: link.y}}
    end
  end

  def gate(%Zone.Npc{}), do: {:error, :no_role}

  @doc "The destination of a town portal row for a player of the level: `0x19C3` invalid index, `0x19C4` level too low."
  @spec town_portal(non_neg_integer(), pos_integer()) :: {:ok, dest()} | {:error, 0x19C3 | 0x19C4}
  def town_portal(index, level) do
    case GameData.fetch(GameData.TownPortal, index) do
      {:ok, %{x: x, y: y} = row} when x >= 0 and y >= 0 ->
        if level < row.min_level,
          do: {:error, 0x19C4},
          else: {:ok, %{map: row.map_name, map_client: row.map_name, x: x, y: y}}

      _none ->
        {:error, 0x19C3}
    end
  end

  @doc "The confirmation menu of a gate (Z02 §6.6): the shown name of the client map, \"Yes\" (0) and \"No\" (1)."
  @spec menu(dest(), 0..0xFFFF, Zone.Grid.point()) :: {:ok, MenuServermenuReq.t()} | {:error, :no_map_info}
  def menu(dest, npc_handle, {x, y}) do
    case GameData.fetch(GameData.MapInfo, dest.map_client) do
      {:ok, %{name: name}} ->
        # shortcut: the texts of Script/MenuString.txt (LinkTitle) and Script/ETC.txt (Yes) are constants,
        # read them from the data directory when server menus get their milestone
        {:ok,
         %MenuServermenuReq{
           title: "Do you want to move to " <> name <> " field?",
           priority: 0,
           npc_handle: npc_handle,
           x: x,
           y: y,
           limit_range: 1000,
           menus: [%ServerMenu{reply: 0, string: "Yes"}, %ServerMenu{reply: 1, string: "No"}]
         }}

      :error ->
        {:error, :no_map_info}
    end
  end

  @doc """
  The map change of the connection's player to `dest` (`map` = the map instance process, `entered_at` = the
  monotonic millisecond of the map entry, `session` = the WorldManager session process).
  """
  @spec run(pid(), Zone.Player.t(), integer(), pid(), dest()) ::
          {:other, MapLinkotherCmd.t()}
          | {:same, Zone.Player.t(), MapLinksameCmd.t()}
          | {:moved, pid(), Zone.Player.t(), MapLinksameCmd.t()}
          | {:error, refusal()}
  def run(map, %Zone.Player{} = player, entered_at, session, dest) do
    with {:ok, info} <- tagged(GameData.fetch(GameData.MapInfo, dest.map_client), :no_map_info),
         {:ok, current} <- tagged(current(map, player.handle), :not_on_map) do
      if dest.map == current.map,
        do: same(map, current, info.id, dest),
        else: other(map, current, entered_at, session, info.id, dest)
    end
  end

  defp same(map, current, map_index, dest) do
    with :ok <- save(current, :auto),
         {:ok, moved} <- Zone.MapInstance.relocate(map, current.handle, {dest.x, dest.y}) do
      {:same, moved, %MapLinksameCmd{map_index: map_index, x: moved.x, y: moved.y}}
    end
  end

  defp other(map, current, entered_at, session, map_index, dest) do
    # max/2: a test clock can be set back while a connection is still in the world.
    minutes = max(div(Clock.monotonic_time(:millisecond) - entered_at, 60_000), 0)

    with {:ok, zone} <- tagged(Cluster.WorldManager.zone_of(current.world_no, dest.map), :not_running),
         :reconnect <- local(map, current, zone, map_index, dest),
         :ok <- save(current, {:leave, minutes}),
         {:ok, parked} <- tagged(remove(map, current.handle), :not_on_map),
         reservation = %{
           character_id: current.character.id,
           map: dest.map,
           x: dest.x,
           y: dest.y,
           node: zone.node,
           player: parked
         },
         {:ok, handle} <- Cluster.Sessions.reserve(session, reservation) do
      {:other,
       %MapLinkotherCmd{
         map_index: map_index,
         x: dest.x,
         y: dest.y,
         zone_ip: zone.host,
         zone_port: zone.port,
         wm_handle: handle
       }}
    end
  end

  # As the original (Z01 §7.1), no reconnect inside one zone: here the same FieldList machine number and both map
  # instances on this node. Handles are per map instance, so a handle in use on the target falls back to the reconnect.
  defp local(map, current, zone, map_index, dest) do
    with true <- zone.node == node() and same_machine?(current.map, dest.map),
         {:ok, target} <- Zone.MapInstance.whereis(current.world_no, dest.map),
         {:ok, arriving} <-
           Zone.Player.arrive(
             current,
             %{kind: :map_change, map: dest.map, x: dest.x, y: dest.y},
             current.address,
             current.conn
           ),
         :ok <- save(current, :auto),
         {:ok, entered} <- enter(target, %{arriving | handle: current.handle}, current.handle) do
      hand_over(map, target, entered, map_index)
    else
      {:error, {:save, _reason}} = refused -> refused
      {:error, :no_free_cell} = refused -> refused
      _other -> :reconnect
    end
  end

  defp hand_over(map, target, entered, map_index) do
    case remove(map, entered.handle) do
      {:ok, _left} ->
        _ = Process.monitor(target)
        {:moved, target, entered, %MapLinksameCmd{map_index: map_index, x: entered.x, y: entered.y}}

      :error ->
        _ = remove(target, entered.handle)
        {:error, :not_on_map}
    end
  end

  defp same_machine?(from, to) do
    case {GameData.lookup(GameData.FieldList, :map_id_client, from),
          GameData.lookup(GameData.FieldList, :map_id_client, to)} do
      {[%{machine: m} | _], [%{machine: m} | _]} -> true
      _other -> false
    end
  end

  defp enter(target, player, handle) do
    Zone.MapInstance.enter(target, player, handle)
  catch
    :exit, _ -> {:error, :map_lost}
  end

  defp save(p, kind) do
    case Persistence.save_character(p.world_no, p.character.id, Zone.Player.saved(p), kind) do
      :ok -> :ok
      {:error, reason} -> {:error, {:save, reason}}
    end
  end

  defp tagged({:ok, value}, _reason), do: {:ok, value}
  defp tagged(:error, reason), do: {:error, reason}

  defp current(map, handle) do
    Zone.MapInstance.player(map, handle)
  catch
    :exit, _ -> :error
  end

  defp remove(map, handle) do
    Zone.MapInstance.leave(map, handle)
  catch
    :exit, _ -> :error
  end
end
