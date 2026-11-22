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

  Chat (flow: `docs/technical/flows/chat.md`): in the world, `0x2001` (normal chat) and `0x201E` (shout) go to the
  map instance (`Zone.MapInstance.chat/4`), which checks them with `Zone.Chat` and relays `0x2002` to the speaker and
  the players in sight, or `0x201F` to every player of the map; a refusal is silent, a spam block answers `0x0848`.
  A `0x2001` line starting with `&` is dropped and never shown: the GM command frame is issue 116. A line with more
  than 76 item links is dropped with an `info` line (above it the relayed `0x201F` can exceed the frame limit). A
  chat packet before `0x1803` is ignored. `0x082F` (in `:loading` and `:in_world`) is answered with
  `0x0830 {ShoutLevel, ShoutDelay}`, which the 2016 client ignores (Z01-B5). Absent until their milestones: the GM
  chat ban and the GM colour bit (7), font and balloon colours (9), the pet keyword (9), Lua chat triggers (10), the
  chat-title counter `0x6006` (6), the megaphone `0x204B` (6), party chat (6).
  """

  @behaviour Net.Handler

  alias Proto.Packets.ActChatReq
  alias Proto.Packets.ActEndoftradeCmd
  alias Proto.Packets.ActShoutCmd
  alias Proto.Packets.BriefinfoInformCmd
  alias Proto.Packets.CharLogoutcancelCmd
  alias Proto.Packets.CharLogoutreadyCmd
  alias Proto.Packets.ItemChargedinvenopenReq
  alias Proto.Packets.ItemRewardinvenopenReq
  alias Proto.Packets.MapLogincompleteCmd
  alias Proto.Packets.MapLoginfailAck
  alias Proto.Packets.MapLoginReq
  alias Proto.Packets.MiscServerparameterAck
  alias Proto.Packets.MiscServerparameterReq
  alias Zone.MapEntry.Placeholders

  # above it the relayed 0x201F can exceed the frame limit of Net.Connection
  @max_item_links 76

  @enforce_keys [:checksums]
  defstruct [:checksums, step: :login, session: :none, entry: :none, map: :none, player: :none, entered_at: :none]

  @type t :: %__MODULE__{
          checksums: [GameData.ClientData.checksum()],
          step: :login | :loading | :in_world | :left,
          session: :none | pid(),
          entry: :none | Cluster.Sessions.entry(),
          map: :none | pid() | :stopped,
          player: :none | Zone.Player.t(),
          entered_at: :none | integer()
        }

  @type entry_failure :: :not_found | :database | :no_map | :game_data | :no_block_data | :full

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
    do: {state, [{:perform, {:login_complete, state.map, p.handle, state.session}}]}

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

  # The GM command frame is issue 116; until then a line starting with & is dropped. It is never shown as chat.
  def handle_packet(%__MODULE__{step: :in_world} = state, %ActChatReq{content: "&" <> _}), do: {state, []}

  def handle_packet(%__MODULE__{step: :in_world} = state, %ActChatReq{item_link_count: n}) when n > @max_item_links,
    do: {state, [{:log, :info, "chat dropped: #{n} item links"}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActChatReq{} = req),
    do: {state, [{:perform, {:chat, state.map, p.handle, :normal, line(req)}}]}

  def handle_packet(%__MODULE__{step: :in_world} = state, %ActShoutCmd{item_link_count: n}) when n > @max_item_links,
    do: {state, [{:log, :info, "shout dropped: #{n} item links"}]}

  def handle_packet(%__MODULE__{step: :in_world, player: %Zone.Player{} = p} = state, %ActShoutCmd{} = req),
    do: {state, [{:perform, {:chat, state.map, p.handle, :shout, line(req)}}]}

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
    do: {%{state | step: :in_world}, for(p <- packets, do: {:send, p})}

  def handle_info(state, {:login_completed, {:error, :not_entered}}),
    do: {state, [{:close, :warning, "map login complete failed: not on the map"}]}

  def handle_info(state, {:informed, packets}), do: {state, for(p <- packets, do: {:send, p})}

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

  def handle_info(%__MODULE__{step: :in_world, map: map, player: %Zone.Player{} = p} = state, {:timer, :auto_save})
      when is_pid(map),
      do: {state, [{:perform, {:auto_save, map, p}}]}

  def handle_info(state, {:timer, :auto_save}), do: {state, []}

  def handle_info(state, {:auto_saved, _id, :ok}), do: {state, []}

  def handle_info(state, {:auto_saved, id, {:error, reason}}),
    do: {state, [{:log, :error, "auto-save failed: character #{id}, " <> save_text(reason)}]}

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

  def perform({:enter, entry}) do
    result =
      with {:ok, character} <- Persistence.load_character(entry.world_no, entry.user_no, entry.character_id),
           {:ok, map} <- whereis(entry),
           {:ok, player} <- Zone.Player.new(character, entry, address(), self()),
           {:ok, handle} <- Zone.MapInstance.enter(map, player) do
        _ = Process.monitor(map)
        {:ok, map, %{player | handle: handle}, Clock.monotonic_time(:millisecond)}
      end

    {:entered, result}
  end

  def perform({:login_complete, map, handle, session}) do
    result = Zone.MapInstance.login_complete(map, handle)

    _ =
      with {:ok, _packets} <- result do
        :ok = Cluster.Sessions.map_login_done(session)
        auto_save_timer()
      end

    {:login_completed, result}
  end

  def perform({:auto_save, map, p}) do
    _ = auto_save_timer()

    result =
      case current(map, p.handle) do
        {:ok, player} -> Persistence.save_character(p.world_no, p.character.id, saved(player), :auto)
        :error -> {:error, :not_on_map}
      end

    {:auto_saved, p.character.id, result}
  end

  def perform({:leave, map, player, entered_at}), do: {:left, leave(map, player, entered_at)}

  def perform({:inform, map, own, handle}), do: {:informed, Zone.MapInstance.inform(map, own, handle)}

  def perform({:chat, map, handle, kind, line}), do: {:chatted, Zone.MapInstance.chat(map, handle, kind, line)}
  def perform(:server_parameters), do: {:server_parameters, Zone.Chat.common().shout}

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

    case Persistence.save_character(p.world_no, p.character.id, saved(p), {:leave, minutes}) do
      :ok -> [{:log, :info, "left the world: character #{p.character.id}, map #{p.map}"}]
      {:error, reason} -> [{:log, :error, "save at leave failed: character #{p.character.id}, " <> save_text(reason)}]
    end
  end

  defp saved(p), do: %{map: p.map, x: p.x, y: p.y, hp: p.character.hp, sp: p.character.sp}

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
end
