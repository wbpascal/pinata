defmodule Zone.Handler do
  @moduledoc """
  Packet handler of the Zone part: the map login `0x1801` (flow: `docs/technical/flows/enter-world.md`) and the map
  entry up to `0x1803` (flow: `docs/technical/flows/map-entry.md`).

  First the Client data check: the 49 checksums of the packet against `GameData.client_checksums/0`. The first
  difference answers `0x1804 {0x147, index}` and closes the connection; the reservation stays. Then one call to the
  WorldManager session with the handle (`Cluster.Sessions.redeem/2`) redeems the map-login ticket. A refusal answers
  `0x1804` with the code of the original WorldManager (Z01-B1 fixed) and closes the connection. From an accepted
  map login on the connection monitors the session and closes when it ends.

  An accepted map login loads the character (`Persistence.load_character/3`), builds its `Zone.Player`, enters it
  into the map instance (mode 0) and sends the burst of `Zone.MapEntry.login/1`. Any failure there answers
  `0x1804 {0x142, 0xFF}` and closes with one `warning` line. On `0x1803` the player becomes visible (mode 1), the
  Zone sends the burst of `Zone.MapEntry.login_complete/1` and the WorldManager session sends its own
  (`Cluster.Sessions.map_login_done/1`). `0x200B` is accepted without an answer; `0x302C` and `0x3020` get the
  empty answers of `Zone.MapEntry.Placeholders`.

  The leave path (flow: `docs/technical/flows/leave-world.md`): the player is removed from the map instance and
  saved (`Persistence.save_character/4`, with the play minutes since the map entry and the logout time). It runs when
  the session asks (`0x0C18 {1}`, `Cluster.Sessions.leave_world/1`; the connection stays open in step `:left`) and
  when the connection ends for any reason but a kill (`terminate/1`): the client closed it, the session ended or was
  replaced, the map instance stopped in order (the connection saves the snapshot the map sent) or the listener
  stopped. A lost map instance closes the connection without a save. From `0x1803` on the player is auto-saved every
  10 minutes; a failed auto-save writes an `error` line and the player stays. `0x1071` and `0x1072` are accepted
  without effect: there are no logout timers.

  Sight (flow: `docs/technical/flows/sight.md`): in the world, `0x1C01` asks the map instance for the appear packet
  of an object (`Zone.MapInstance.inform/3`); the client's own handle field is ignored and an object out of sight,
  unknown or the requester itself gets no answer. The packets the map instance pushes for this player
  (`{:cluster, {:packets, packets}}`: appears, disappears, `0x1805`, chat lines) are sent in the world and dropped
  before.

  Movement (flow: `docs/technical/flows/movement.md`): in the world, `0x2017` walk, `0x2019` run and `0x2012` stop go
  to the map instance (`Zone.MapInstance.move/5`, `stop/3`), which checks them against the server position and the
  block data. Every answer (`0x201B`, `0x204A`) and every packet for this player comes as
  `{:cluster, {:packets, packets}}`; the map sends them before it replies, so the connection takes them from its
  mailbox right after the call and sends them before it reads the next frame (a heartbeat in the same TCP read would
  otherwise be answered first). Before the world these packets get no answer.

  Chat (flow: `docs/technical/flows/chat.md`): in the world, `0x2001` (normal chat) and `0x201E` (shout) go to the
  map instance (`Zone.MapInstance.chat/4`), which checks them with `Zone.Chat` and relays `0x2002` to the speaker and
  the players in sight, or `0x201F` to every player of the map; a refusal is silent, a spam block answers `0x0848`.
  A `0x2001` line starting with `&` is a GM command and never shown as chat (see "GM commands"). A line with more
  than 76 item links is dropped with an `info` line (above it the relayed `0x201F` can exceed the frame limit). A
  chat packet before `0x1803` is ignored. `0x082F` (in `:loading` and `:in_world`) is answered with
  `0x0830 {ShoutLevel, ShoutDelay}`, which the 2016 client ignores (Z01-B5). Absent until their milestones: the GM
  chat ban and the GM colour bit (7), font and balloon colours (9), the pet keyword (9), Lua chat triggers (10), the
  chat-title counter `0x6006` (6), the megaphone `0x204B` (6), party chat (6).

  Map change (flow: `docs/technical/flows/map-change.md`, `Zone.Link`): in the world, `0x200A` on a Gate NPC within
  1000 units opens the menu `0x3C01` with the `LinkTable` destination; the answer `0x3C02 {0}` within 1000 units of
  where the menu opened runs the change, any other answer closes the menu. `0x181A` near a town portal NPC
  (`Gate_Town`) runs the change to the `TownPortal.shn` row and answers `0x181B` (`0x19C1` before `0x180A`, or the
  refusal code). The change to another map instance saves the player, removes it from the map, parks it in the
  session and sends `0x180A`; the connection stays open in step `:left` until the client closes it. A change inside
  the map instance sends `0x1809` and returns to step `:loading`; the next `0x1803` runs the burst again (one auto-save
  timer per connection). A change to another map instance of this node with the same `FieldList` machine number (the
  original's "same zone") also sends `0x1809` on the same connection, the handle kept; the player moves to the target
  instance (`Zone.MapInstance.enter/3`), and a handle in use there falls back to `0x180A`. The new connection redeems
  the reservation as an entry of kind `:map_change`: no database load, the parked player arrives on the reserved map and
  position (`Zone.Player.arrive/4`).

  Actions (flow: `docs/technical/flows/actions.md`): in the world, `0x2020` emote, `0x2022` emote stop, `0x2024`
  jump and `0x2008` stance go to the map instance (`Zone.MapInstance.action/3`), which relays `0x2021` / `0x2023` to
  the player and the players in sight, `0x2025` / `0x2009` to the players in sight. An emote id without an
  `ActionViewInfo` row, a charged emote (`eActionType` 2) through `0x2020`, and a stance other than 1 or 2 are
  ignored with an `info` line; the connection stays open. Before `0x1803` the four packets are ignored. Absent until
  their milestones: the gamble-game refusal of `0x2020`, `CancelOnAction`, charged emotes `0x2067` (9), the pet
  dance (9), the tent shape of `0x2008`, the Lua jump triggers (10), the quest hook (5).

  GM commands (flow: `docs/technical/flows/gm-commands.md`, `Zone.GmCommand`): in the world, a `0x2001` line that
  starts with `&` is checked before every chat rule. A character with admin level 0 gets no answer and no log line.
  Otherwise the line is cut at 100 bytes, logged (`info`, `GM command: character …: …`, Z11-B1 fixed) and parsed;
  an unknown word answers `0x2011` "Invalid command : <word>", a known word with too low a level nothing.
  `&adminlevel` answers "Admin level is <n>". `&hide`, `&show` and `&dimension <n>` go to the map instance
  (`Zone.MapInstance.action/3`). `&kickout <name>` finds the session of the name on any node and kicks it
  (`Cluster.Sessions.kick/2`), answering "<name> is banned" (P02-B41 fixed) or "<name> is not in game" (Z11-B6
  fixed); it does not wait for the kick. `&linkto` runs the map change (`Zone.Link.run/5`) to a free spot of the own
  map (no argument), the `RegenX` / `RegenY` point of `MapInfo` (`<map>`) or a point (`<map> <x> <y>`); an unknown
  map, a map that is not running and `&linkto -` answer "Invalid map name". A kick of this connection's character
  (`{:cluster, :kicked}` from the session) closes the connection; `terminate/1` saves the player.
  """

  @behaviour Net.Handler

  alias Proto.Packets.ActChangemodeReq
  alias Proto.Packets.ActChatReq
  alias Proto.Packets.ActEmoticonCmd
  alias Proto.Packets.ActEmoticonstopCmd
  alias Proto.Packets.ActEndoftradeCmd
  alias Proto.Packets.ActJumpCmd
  alias Proto.Packets.ActMoverunCmd
  alias Proto.Packets.ActNoticeCmd
  alias Proto.Packets.ActNpcclickCmd
  alias Proto.Packets.ActMovewalkCmd
  alias Proto.Packets.ActShoutCmd
  alias Proto.Packets.ActStopReq
  alias Proto.Packets.BriefinfoInformCmd
  alias Proto.Packets.CharLogoutcancelCmd
  alias Proto.Packets.CharLogoutreadyCmd
  alias Proto.Packets.ItemChargedinvenopenReq
  alias Proto.Packets.ItemRewardinvenopenReq
  alias Proto.Packets.MapLogincompleteCmd
  alias Proto.Packets.MapLoginfailAck
  alias Proto.Packets.MapLoginReq
  alias Proto.Packets.MapTownportalAck
  alias Proto.Packets.MapTownportalReq
  alias Proto.Packets.MenuServermenuAck
  alias Proto.Packets.MiscServerparameterAck
  alias Proto.Packets.MiscServerparameterReq
  alias Zone.MapEntry.Placeholders

  # above it the relayed 0x201F can exceed the frame limit of Net.Connection
  @max_item_links 76
  # the answer to a gate menu counts within 1000 units of where it opened: dist² ≤ 1 000 000 (Z02 §6.6)
  @menu_reach2 1_000_000

  @enforce_keys [:checksums]
  defstruct [:checksums, step: :login, session: :none, entry: :none, map: :none, player: :none, entered_at: :none] ++
              [menu: :none, auto_save?: false]

  @type t :: %__MODULE__{
          checksums: [GameData.ClientData.checksum()],
          step: :login | :loading | :in_world | :left,
          session: :none | pid(),
          entry: :none | Cluster.Sessions.entry(),
          map: :none | pid() | :stopped,
          player: :none | Zone.Player.t(),
          entered_at: :none | integer(),
          menu: :none | {Zone.Link.dest(), Zone.Grid.point(), binary()},
          auto_save?: boolean()
        }

  @type entry_failure :: :not_found | :database | :no_map | :game_data | :no_block_data | :full | :no_free_cell

  @impl Net.Handler
  def init(_settings), do: %__MODULE__{checksums: GameData.client_checksums()}

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :login} = state, %MapLoginReq{wm_handle: h, char_name: name, checksums: theirs}) do
    case GameData.ClientData.first_difference(state.checksums, theirs) do
      {index, table, ours, client} ->
        {state,
         [
           {:send, %MapLoginfailAck{error: 0x147, wrong_data_file_index: index}},
           {:close, :warning,
            "Client data check failed: character #{inspect(name)}, table #{table}, server #{ours}, client #{inspect(client)}"}
         ]}

      :none ->
        {state, [{:perform, {:redeem, h, name}}]}
    end
  end

  def handle_packet(%__MODULE__{step: :loading, player: %Zone.Player{} = p} = state, %MapLogincompleteCmd{}),
    do: {state, [{:perform, {:login_complete, state.map, p.handle, state.session, state.auto_save?}}]}

  # Accepted without an answer, as the original after a map login (issue 88).
  def handle_packet(%__MODULE__{step: step} = state, %ActEndoftradeCmd{}) when step in [:loading, :in_world],
    do: {state, []}

  def handle_packet(%__MODULE__{step: step} = state, %ItemRewardinvenopenReq{}) when step in [:loading, :in_world],
    do: {state, [{:send, Placeholders.reward_inventory()}]}

  def handle_packet(%__MODULE__{step: step} = state, %ItemChargedinvenopenReq{}) when step in [:loading, :in_world],
    do: {state, [{:send, Placeholders.charged_inventory()}]}

  # Accepted without effect: no logout timers (issue 94).
  def handle_packet(%__MODULE__{step: step} = state, %CharLogoutreadyCmd{}) when step in [:loading, :in_world],
    do: {state, []}

  def handle_packet(%__MODULE__{step: step} = state, %CharLogoutcancelCmd{}) when step in [:loading, :in_world],
    do: {state, []}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %BriefinfoInformCmd{handle: h}),
    do: {state, [{:perform, {:inform, state.map, p.handle, h}}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActMovewalkCmd{} = m),
    do: {state, [{:perform, {:move, state.map, p.handle, :walk, {m.from_x, m.from_y}, {m.to_x, m.to_y}}}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActMoverunCmd{} = m),
    do: {state, [{:perform, {:move, state.map, p.handle, :run, {m.from_x, m.from_y}, {m.to_x, m.to_y}}}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActStopReq{x: x, y: y}),
    do: {state, [{:perform, {:stop, state.map, p.handle, {x, y}}}]}

  # A line starting with & is a GM command, checked before every chat rule; never shown as chat.
  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{admin_level: 0}} = state, %ActChatReq{
        content: "&" <> _
      }),
      do: {state, []}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActChatReq{
        content: "&" <> _ = content
      }),
      do: {state, gm_command(state, p, content)}

  def handle_packet(%__MODULE__{step: :in_world} = state, %ActChatReq{item_link_count: n}) when n > @max_item_links,
    do: {state, [{:log, :info, "chat dropped: #{n} item links"}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActChatReq{} = req),
    do: {state, [{:perform, {:chat, state.map, p.handle, :normal, line(req)}}]}

  def handle_packet(%__MODULE__{step: :in_world} = state, %ActShoutCmd{item_link_count: n}) when n > @max_item_links,
    do: {state, [{:log, :info, "shout dropped: #{n} item links"}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActShoutCmd{} = req),
    do: {state, [{:perform, {:chat, state.map, p.handle, :shout, line(req)}}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActNpcclickCmd{npc_handle: h}),
    do: {state, [{:perform, {:npc_click, state.map, p.handle, h}}]}

  def handle_packet(
        %__MODULE__{step: :in_world, player: %Zone.Player{} = p, menu: {dest, origin, name}} = state,
        %MenuServermenuAck{reply: 0}
      ),
      do:
        {%{state | menu: :none},
         [{:perform, {:link, {:gate, name, origin}, state.map, p, state.entered_at, state.session, dest}}]}

  def handle_packet(%__MODULE__{step: :in_world} = state, %MenuServermenuAck{}), do: {%{state | menu: :none}, []}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %MapTownportalReq{index: i}),
    do: {state, [{:perform, {:town_portal, i, state.map, p, state.entered_at, state.session}}]}

  def handle_packet(%__MODULE__{step: :loading} = state, %MapTownportalReq{}),
    do: {state, [{:send, %MapTownportalAck{error: 0x19C2}}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActEmoticonCmd{emoticon_id: id}) do
    case GameData.fetch(GameData.ActionViewInfo, id) do
      # a charged emote plays through an item (milestone 9)
      {:ok, %{action_type: 2}} -> {state, [{:log, :info, "emote ignored: charged emote #{id}"}]}
      {:ok, _row} -> {state, [{:perform, {:action, state.map, p.handle, {:emote, id}}}]}
      :error -> {state, [{:log, :info, "emote ignored: unknown id #{id}"}]}
    end
  end

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActEmoticonstopCmd{} = e) do
    case GameData.fetch(GameData.ActionViewInfo, e.emoticon_id) do
      {:ok, _row} ->
        {state, [{:perform, {:action, state.map, p.handle, {:emote_stop, e.emoticon_id, e.emoticon_frame}}}]}

      :error ->
        {state, [{:log, :info, "emote stop ignored: unknown id #{e.emoticon_id}"}]}
    end
  end

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActJumpCmd{}),
    do: {state, [{:perform, {:action, state.map, p.handle, :jump}}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActChangemodeReq{mode: mode})
      when mode in [1, 2],
      do: {state, [{:perform, {:action, state.map, p.handle, {:stance, mode}}}]}

  def handle_packet(%__MODULE__{step: :in_world} = state, %ActChangemodeReq{mode: mode}),
    do: {state, [{:log, :info, "stance ignored: mode #{mode}"}]}

  def handle_packet(%__MODULE__{step: step} = state, %MiscServerparameterReq{}) when step in [:loading, :in_world],
    do: {state, [{:perform, :server_parameters}]}

  def handle_packet(state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:redeemed, {:ok, pid, entry}}),
    do:
      {%{state | session: pid, entry: entry},
       [
         {:log, :info, "map login accepted: character #{entry.character_id}, map #{entry.map}"},
         {:perform, {:enter, entry}}
       ]}

  # Z01-B1 fixed: the refusal carries the real code.
  def handle_info(state, {:redeemed, {:error, reason}}),
    do:
      {state,
       [
         {:send, %MapLoginfailAck{error: code(reason), wrong_data_file_index: 0xFF}},
         {:close, :info, "map login refused: " <> text(reason)}
       ]}

  def handle_info(state, {:entered, {:ok, map, player, entered_at}}),
    do:
      {%{state | step: :loading, map: map, player: player, entered_at: entered_at},
       for(p <- Zone.MapEntry.login(player), do: {:send, p})}

  # 0x142: the original's code when the player cannot be placed on the map.
  def handle_info(state, {:entered, {:error, reason}}),
    do:
      {state,
       [
         {:send, %MapLoginfailAck{error: 0x142, wrong_data_file_index: 0xFF}},
         {:close, :warning, "map entry failed: " <> entry_text(reason)}
       ]}

  def handle_info(state, {:login_completed, {:ok, packets}}),
    do: {%{state | step: :in_world, auto_save?: true}, for(p <- packets, do: {:send, p})}

  def handle_info(state, {:login_completed, {:error, :not_entered}}),
    do: {state, [{:close, :warning, "map login complete failed: not on the map"}]}

  def handle_info(state, {:informed, packets}), do: {state, for(p <- packets, do: {:send, p})}

  def handle_info(state, {:moved, packets}), do: {state, for(p <- packets, do: {:send, p})}
  def handle_info(state, {:chatted, packets}), do: {state, for(p <- packets, do: {:send, p})}

  def handle_info(state, {:server_parameters, %{level: level, delay_s: delay}}),
    do: {state, [{:send, %MiscServerparameterAck{shout_level: level, shout_delay: delay}}]}

  def handle_info(state, {:server_parameters, :off}),
    do: {state, [{:log, :debug, "0x082F not answered: ShoutLevel or ShoutDelay missing in ChrCommon"}]}

  # a player not yet in the world (mode 0) receives nothing
  def handle_info(%__MODULE__{step: :in_world} = state, {:cluster, {:packets, packets}}),
    do: {state, for(p <- packets, do: {:send, p})}

  def handle_info(state, {:cluster, {:packets, _packets}}), do: {state, []}

  def handle_info(%__MODULE__{session: pid} = state, {:down, pid}), do: {state, [{:close, :info, "session ended"}]}

  # terminate/1 then finds the map dead and saves nothing.
  def handle_info(%__MODULE__{map: pid} = state, {:down, pid}), do: {state, [{:close, :warning, "map instance lost"}]}
  def handle_info(state, {:down, _other}), do: {state, []}

  def handle_info(%__MODULE__{step: step} = state, {:cluster, {:map_stopped, player}})
      when step in [:loading, :in_world],
      do: {%{state | map: :stopped, player: player}, [{:close, :info, "map instance stopped"}]}

  def handle_info(state, {:cluster, {:map_stopped, _player}}), do: {state, []}

  def handle_info(state, {:cluster, :session_replaced}), do: {state, [{:close, :info, "session replaced"}]}
  def handle_info(state, {:cluster, :kicked}), do: {state, [{:close, :info, "kicked"}]}

  def handle_info(state, {:gm_notice, text}), do: {state, [{:send, %ActNoticeCmd{unused: 0, text: text}}]}
  def handle_info(state, {:gm_ignored, text}), do: {state, [{:log, :info, text}]}

  def handle_info(%__MODULE__{step: :in_world, map: map, player: %Zone.Player{} = p} = state, {:timer, :auto_save})
      when is_pid(map),
      do: {state, [{:perform, {:auto_save, map, p}}]}

  # not in world (a 0x1809 in progress): the next 0x1803 arms the timer again
  def handle_info(state, {:timer, :auto_save}), do: {%{state | auto_save?: false}, []}

  def handle_info(state, {:auto_saved, _id, :ok}), do: {state, []}

  def handle_info(state, {:auto_saved, id, {:error, reason}}),
    do: {state, [{:log, :error, "auto-save failed: character #{id}, " <> save_text(reason)}]}

  def handle_info(state, {:npc_clicked, :none}), do: {state, []}
  def handle_info(state, {:npc_clicked, {:log, level, text}}), do: {state, [{:log, level, text}]}

  def handle_info(state, {:npc_clicked, {:menu, menu, packet}}), do: {%{state | menu: menu}, [{:send, packet}]}

  def handle_info(state, {:town_portal_refused, code}), do: {state, [{:send, %MapTownportalAck{error: code}}]}

  def handle_info(state, {:linked, origin, p, dest, {:other, cmd}}),
    do:
      {%{state | step: :left, map: :none, player: :none, menu: :none},
       ack(origin) ++
         [{:log, :info, "map change: character #{p.character.id}, map #{p.map} to #{dest.map}"}, {:send, cmd}]}

  def handle_info(state, {:linked, origin, _p, _dest, {:same, player, cmd}}),
    do: {%{state | step: :loading, player: player, menu: :none}, ack(origin) ++ [{:send, cmd}]}

  # One connection, one auto-save timer: the next 0x1803 arms it again.
  def handle_info(state, {:linked, origin, p, dest, {:moved, map, player, cmd}}),
    do:
      {%{state | step: :loading, map: map, player: player, menu: :none},
       ack(origin) ++
         [{:log, :info, "map change: character #{p.character.id}, map #{p.map} to #{dest.map}"}, {:send, cmd}]}

  # The player is saved and removed already; nothing to answer.
  def handle_info(state, {:linked, _origin, _p, _dest, {:error, :no_session}}),
    do:
      {%{state | step: :left, map: :none, player: :none, menu: :none},
       [{:close, :warning, "map change failed: no session"}]}

  def handle_info(state, {:linked, _origin, _p, _dest, {:error, :too_far}}),
    do: {state, [{:log, :debug, "server menu answer dropped: too far from where the menu opened"}]}

  def handle_info(state, {:linked, :gm, _p, _dest, {:error, reason}}) when reason in [:not_running, :no_map_info],
    do: {state, [{:send, %ActNoticeCmd{unused: 0, text: "Invalid map name"}}]}

  # The line comes before the answer, as the WorldManager refusals do.
  def handle_info(state, {:linked, origin, p, dest, {:error, reason}}),
    do: {state, [{:log, level(reason), refusal_text(origin, p, dest, reason)} | refuse(origin)]}

  def handle_info(state, {:left, lines}), do: {%{state | step: :left, map: :none, player: :none}, lines}

  # The session leaves the world (0x0C18 {1}); the reply goes out after the save.
  @impl Net.Handler
  def handle_call(%__MODULE__{step: step} = state, :leave) when step in [:loading, :in_world],
    do: {:ok, state, [{:perform, {:leave, state.map, state.player, state.entered_at}}]}

  def handle_call(state, :leave), do: {:ok, state, []}

  @impl Net.Handler
  def terminate(%__MODULE__{step: step, player: %Zone.Player{} = p} = state) when step in [:loading, :in_world],
    do: leave(state.map, p, state.entered_at)

  def terminate(_state), do: []

  @impl Net.Handler
  def perform({:redeem, h, name}) do
    result = Cluster.Sessions.redeem(h, name)

    _ =
      with {:ok, pid, entry} <- result do
        _ = Process.monitor(pid)
        Cluster.Sessions.join(entry.user_no)
      end

    {:redeemed, result}
  end

  def perform({:enter, %{kind: :map_change} = entry}) do
    result =
      with {:ok, map} <- whereis(entry),
           {:ok, player} <- Zone.Player.arrive(entry.player, entry, address(), self()),
           {:ok, entered} <- Zone.MapInstance.enter(map, player) do
        _ = Process.monitor(map)
        {:ok, map, entered, Clock.monotonic_time(:millisecond)}
      end

    {:entered, result}
  end

  def perform({:enter, %{kind: :first_entry} = entry}) do
    result =
      with {:ok, character} <- Persistence.load_character(entry.world_no, entry.user_no, entry.character_id),
           {:ok, map} <- whereis(entry),
           {:ok, player} <- Zone.Player.new(character, entry, address(), self()),
           {:ok, entered} <- Zone.MapInstance.enter(map, player) do
        _ = Process.monitor(map)
        {:ok, map, entered, Clock.monotonic_time(:millisecond)}
      end

    {:entered, result}
  end

  def perform({:login_complete, map, handle, session, timer?}) do
    result = Zone.MapInstance.login_complete(map, handle)

    _ =
      with {:ok, _packets} <- result do
        :ok = Cluster.Sessions.map_login_done(session)
        # after 0x1809 the timer of the first 0x1803 runs on
        if not timer?, do: auto_save_timer()
      end

    {:login_completed, result}
  end

  def perform({:auto_save, map, p}) do
    _ = auto_save_timer()

    result =
      case current(map, p.handle) do
        {:ok, player} -> Persistence.save_character(p.world_no, p.character.id, Zone.Player.saved(player), :auto)
        :error -> {:error, :not_on_map}
      end

    {:auto_saved, p.character.id, result}
  end

  def perform({:leave, map, player, entered_at}), do: {:left, leave(map, player, entered_at)}

  def perform({:npc_click, map, own, h}) do
    case Zone.MapInstance.npc(map, own, h) do
      {:ok, npc, point} -> {:npc_clicked, gate_menu(npc, h, point)}
      :error -> {:npc_clicked, :none}
    end
  end

  def perform({:link, {:gate, _name, origin} = how, map, p, entered_at, session, dest}) do
    case current(map, p.handle) do
      {:ok, %Zone.Player{x: x, y: y}} ->
        if dist2({x, y}, origin) <= @menu_reach2,
          do: {:linked, how, p, dest, Zone.Link.run(map, p, entered_at, session, dest)},
          else: {:linked, how, p, dest, {:error, :too_far}}

      :error ->
        {:linked, how, p, dest, {:error, :not_on_map}}
    end
  end

  def perform({:link, :town_portal, map, p, entered_at, session, dest}),
    do: {:linked, :town_portal, p, dest, Zone.Link.run(map, p, entered_at, session, dest)}

  def perform({:link, :gm, map, p, entered_at, session, dest}),
    do: {:linked, :gm, p, dest, Zone.Link.run(map, p, entered_at, session, dest)}

  def perform({:kickout, world_no, name}) do
    case Cluster.Sessions.find_character(world_no, name) do
      {:ok, pid} ->
        :ok = Cluster.Sessions.kick(pid, 0x068B)
        {:gm_notice, name <> " is banned"}

      :error ->
        {:gm_notice, name <> " is not in game"}
    end
  end

  def perform({:gm_linkto, [], map, p, entered_at, session}) do
    case free_spot(map) do
      {:ok, {x, y}} -> perform({:link, :gm, map, p, entered_at, session, %{map: p.map, map_client: p.map, x: x, y: y}})
      :error -> {:gm_ignored, "&linkto ignored: no free spot found"}
    end
  end

  # shortcut: &linkto - (back to the normal location) is not built (issue 93)
  def perform({:gm_linkto, ["-" <> _ | _], _map, _p, _entered_at, _session}), do: {:gm_notice, "Invalid map name"}

  def perform({:gm_linkto, [name | rest], map, p, entered_at, session}) do
    with {:ok, info} <- GameData.fetch(GameData.MapInfo, name),
         {x, y} when x >= 0 and y >= 0 <- linkto_point(rest, info) do
      perform({:link, :gm, map, p, entered_at, session, %{map: name, map_client: name, x: x, y: y}})
    else
      :error -> {:gm_notice, "Invalid map name"}
      {_x, _y} -> {:gm_ignored, "&linkto ignored: coordinates out of range"}
    end
  end

  # not in the original: it accepts 0x181A anywhere, a free teleport for a modified client
  def perform({:town_portal, i, map, p, entered_at, session}) do
    with true <- Zone.MapInstance.near_npc?(map, p.handle, "Gate_Town"),
         {:ok, dest} <- Zone.Link.town_portal(i, p.character.level) do
      perform({:link, :town_portal, map, p, entered_at, session, dest})
    else
      false -> {:town_portal_refused, 0x19C2}
      {:error, code} -> {:town_portal_refused, code}
    end
  end

  def perform({:inform, map, own, handle}), do: {:informed, Zone.MapInstance.inform(map, own, handle)}

  def perform({:move, map, own, kind, from, to}), do: moved(Zone.MapInstance.move(map, own, kind, from, to))

  def perform({:stop, map, own, loc}), do: moved(Zone.MapInstance.stop(map, own, loc))
  def perform({:action, map, own, action}), do: moved(Zone.MapInstance.action(map, own, action))

  def perform({:chat, map, handle, kind, line}), do: {:chatted, Zone.MapInstance.chat(map, handle, kind, line)}
  def perform(:server_parameters), do: {:server_parameters, Zone.Chat.common().shout}

  # so_ply_AdminCommand (Z11 §1): the line is cut at 100 bytes and logged before the lookup (Z11-B1 fixed)
  defp gm_command(state, p, content) do
    line = binary_part(content, 0, min(byte_size(content), 100))
    {word, args} = Zone.GmCommand.parse(line)
    log = {:log, :info, "GM command: character #{inspect(p.character.name)}: #{inspect(line)}"}
    [log | gm(Zone.GmCommand.lookup(word, p.admin_level), word, args, state, p)]
  end

  defp gm(:unknown, word, _args, _state, _p),
    do: [{:send, %ActNoticeCmd{unused: 0, text: "Invalid command : " <> word}}]

  defp gm(:denied, _word, _args, _state, _p), do: []

  defp gm({:ok, :adminlevel}, _word, _args, _state, p),
    do: [{:send, %ActNoticeCmd{unused: 0, text: "Admin level is #{p.admin_level}"}}]

  defp gm({:ok, :hide}, _word, _args, state, p), do: [{:perform, {:action, state.map, p.handle, :hide}}]
  defp gm({:ok, :show}, _word, _args, state, p), do: [{:perform, {:action, state.map, p.handle, :show}}]

  defp gm({:ok, :dimension}, _word, args, state, p),
    do: [{:perform, {:action, state.map, p.handle, {:dimension, Zone.GmCommand.number(first(args))}}}]

  defp gm({:ok, :kickout}, _word, args, _state, p), do: [{:perform, {:kickout, p.world_no, first(args)}}]

  defp gm({:ok, :linkto}, _word, args, state, p),
    do: [{:perform, {:gm_linkto, args, state.map, p, state.entered_at, state.session}}]

  defp first([arg | _]), do: arg
  defp first([]), do: ""

  # exactly two numbers name the point; any other count takes the regen point of the map
  defp linkto_point([xs, ys], _info), do: {Zone.GmCommand.number(xs), Zone.GmCommand.number(ys)}
  defp linkto_point(_rest, info), do: {info.regen_x, info.regen_y}

  defp free_spot(map) do
    Zone.MapInstance.free_spot(map)
  catch
    :exit, _ -> :error
  end

  # the packets the map instance sent this connection before its reply (one sender: they are in the mailbox)
  defp moved(_result), do: {:moved, pushed([])}

  defp pushed(acc) do
    receive do
      {:cluster, {:packets, packets}} -> pushed(acc ++ packets)
    after
      0 -> acc
    end
  end

  defp line(%{item_link_count: n, content: content, links: links}),
    do: %{item_link_count: n, content: content, links: links}

  defp auto_save_timer,
    do: Process.send_after(self(), {:timer, :auto_save}, Application.get_env(:pinata, :auto_save_ms, 600_000))

  defp current(map, handle) do
    Zone.MapInstance.player(map, handle)
  catch
    :exit, _ -> :error
  end

  # The one leave path: removed from the map (or the snapshot of a map stopped in order), then saved.
  defp leave(:stopped, player, entered_at), do: save_at_leave(player, entered_at)

  defp leave(map, player, entered_at) when is_pid(map) do
    case remove(map, player.handle) do
      {:ok, current} -> save_at_leave(current, entered_at)
      :error -> []
    end
  end

  defp remove(map, handle) do
    Zone.MapInstance.leave(map, handle)
  catch
    :exit, _ -> :error
  end

  defp save_at_leave(p, entered_at) do
    # max/2: a test clock can be set back while a connection is still in the world.
    minutes = max(div(Clock.monotonic_time(:millisecond) - entered_at, 60_000), 0)

    case Persistence.save_character(p.world_no, p.character.id, Zone.Player.saved(p), {:leave, minutes}) do
      :ok -> [{:log, :info, "left the world: character #{p.character.id}, map #{p.map}"}]
      {:error, reason} -> [{:log, :error, "save at leave failed: character #{p.character.id}, " <> save_text(reason)}]
    end
  end

  defp gate_menu(%Zone.Npc{row: %{map: map}} = npc, h, point) do
    case Zone.Link.gate(npc) do
      {:error, :no_role} ->
        {:log, :debug, "NPC click dropped: role #{npc.row.role} is not built"}

      {:error, :no_link} ->
        {:log, :info, "gate #{npc.row.mob_name} on map #{map}: no LinkTable row for #{npc.row.role_arg}"}

      {:ok, dest} ->
        case Zone.Link.menu(dest, h, point) do
          {:ok, packet} ->
            {:menu, {dest, point, npc.row.mob_name}, packet}

          {:error, :no_map_info} ->
            {:log, :info, "gate #{npc.row.mob_name} on map #{map}: no MapInfo row for #{dest.map_client}"}
        end
    end
  end

  defp ack(:town_portal), do: [{:send, %MapTownportalAck{error: 0x19C1}}]
  defp ack({:gate, _name, _origin}), do: []
  defp ack(:gm), do: []

  defp refuse(:town_portal), do: [{:send, %MapTownportalAck{error: 0x19C2}}]
  defp refuse({:gate, _name, _origin}), do: []
  defp refuse(:gm), do: []

  defp level(:not_running), do: :info
  defp level(:no_map_info), do: :info
  defp level({:save, _reason}), do: :error
  defp level(:not_on_map), do: :warning
  defp level(:no_free_cell), do: :warning

  defp refusal_text({:gate, name, _origin}, p, dest, :not_running),
    do: "gate #{name} on map #{p.map}: destination #{dest.map} is not running"

  defp refusal_text(:town_portal, _p, dest, :not_running), do: "town portal refused: map #{dest.map} is not running"
  defp refusal_text(_origin, _p, dest, :no_map_info), do: "map change refused: no MapInfo row for #{dest.map_client}"

  defp refusal_text(_origin, p, _dest, {:save, reason}),
    do: "map change refused: save failed: character #{p.character.id}, " <> save_text(reason)

  defp refusal_text(_origin, _p, _dest, :not_on_map), do: "map change failed: not on the map"

  defp refusal_text(_origin, _p, dest, :no_free_cell),
    do: "map change refused: no free cell on #{dest.map} around (#{dest.x}, #{dest.y})"

  defp dist2({ax, ay}, {bx, by}), do: (ax - bx) * (ax - bx) + (ay - by) * (ay - by)

  defp save_text(:not_found), do: "character not found"
  defp save_text(:database), do: "database failure"
  defp save_text(:not_on_map), do: "not on the map"

  defp whereis(entry) do
    case Zone.MapInstance.whereis(entry.world_no, entry.map) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :no_map}
    end
  end

  # The peer metadata set by Net.Connection: "address:port".
  defp address do
    case Logger.metadata()[:peer] do
      peer when is_binary(peer) -> peer |> String.split(":") |> Enum.drop(-1) |> Enum.join(":")
      _none -> ""
    end
  end

  defp code(:no_session), do: 0x141
  defp code(:no_ticket), do: 0x141
  defp code(:wrong_node), do: 0x141
  defp code(:wrong_character), do: 0x590

  defp text(:no_session), do: "no session for the handle"
  defp text(:no_ticket), do: "no map-login ticket"
  defp text(:wrong_node), do: "reserved for another Zone node"
  defp text(:wrong_character), do: "not the reserved character"

  defp entry_text(:not_found), do: "character not found"
  defp entry_text(:database), do: "database failure"
  defp entry_text(:no_map), do: "no map instance"
  defp entry_text(:game_data), do: "a game data row is missing"
  defp entry_text(:no_block_data), do: "block data unreadable"
  defp entry_text(:full), do: "map instance full"
  defp entry_text(:no_free_cell), do: "no free cell"
end
