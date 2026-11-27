defmodule WorldManager.Handler do
  @moduledoc """
  Packet handler of the WorldManager part: the login of a client that was handed over by Login (`0x0C0F`; flow:
  `docs/technical/flows/world-select.md`).

  The login is accepted only for a reservation with the same key and the same user name (W01-B1 fixed). An accepted
  connection becomes the session of the account and counts as a player of the world. It then gets the character list
  `0x0C14` (also on `0x0C1F`) and answers `0x080D` with `0x080E` (flow: `docs/technical/flows/character-list.md`).

  `0x1401` creates a character and answers `0x1406` or `0x1404` (flow: `docs/technical/flows/character-create.md`).

  `0x1407` deletes the character of a slot and answers `0x140C` or `0x140A` (flow: `docs/technical/flows/character-delete.md`).

  `0x140F` renames the character of a slot and answers `0x1410` (`0xD0` or `0xD1`); `0xB409` always answers `0xB40C`
  with `0x20C3`, no rename right (flow: `docs/technical/flows/character-rename.md`).

  `0x1001` enters the world with the character of a slot: it keeps a reservation (the map-login ticket) for the Zone
  node that runs the character's stored map and answers `0x1003` with that node's address, or `0x1002`. Right after
  `0x1003` it pushes `0x7032`, `0x7033` and `0x7034` empty (`WorldManager.Placeholders`); the client waits for them
  before it enters the world. A character with tutorial state 0 is first asked `0x1110`; a skip (`0x1111`) saves
  state 2 and goes on. The Zone redeems the ticket with `handle_call/2` on `0x1801`; from then on the session monitors the Zone connection (flow:
  `docs/technical/flows/enter-world.md`).

  After a map login the client asks for its options and prison state: `0x7004`, `0x700C` and `0x7C06` get the empty
  answers of `WorldManager.Placeholders`; the first `0x581B` gets `0x581C` with the server time (the Kingdom Quest
  list `0x581D` is milestone 10), later ones nothing. When the Zone reports `0x1803` (`{:cluster, :map_login_done}`)
  the session sends its burst: `0x1097`, `0x1012`, `0x9414`, `0x5826`, `0x10D9` (placeholders), `0x0849` and `0x182A`
  (flow: `docs/technical/flows/map-entry.md`); after a map change only `0x5826` and `0x182A`.

  A map change (flow: `docs/technical/flows/map-change.md`): the old Zone connection parks the player in the session
  (`{:reserve, zone, r}`, `Cluster.Sessions.reserve/2`; accepted only from the session's current Zone connection)
  and gets the session handle for `0x180A`. The reservation has the kind `:map_change`, the target map and position
  and the player struct; the new Zone connection redeems it like a first entry (wrong node: `:wrong_node`, the
  reservation stays) and gets the struct in its entry. While it is open the session has no Zone connection. It has
  no timer and ends with the session, with the next `0x1001` or with `0x0C18 {1}`.

  `0x200C` whispers to a character by name (flow: `docs/technical/flows/whisper.md`). Only a session whose character
  is in the world (its map-login ticket was redeemed, until its next accepted `0x1001`) can whisper or be whispered
  to; a session at character select that whispers gets no answer. An empty text is echoed at once with `0x200F` and
  count 0 (W04-B4 fixed). Otherwise the receiver is looked up in the world on any node, ASCII letter case ignored
  (`Cluster.Sessions.find_character/2`): not found answers `0x200E` with `0x0F69`, a text of 129 bytes or more
  `0x0F6B` (W04-B5 kept: the client shows nothing for it); else the receiver's session sends `0x200D` and the sender
  gets `0x200F` with the receiver's stored spelling. Item links are relayed as opaque bytes; a packet whose size does
  not match them is dropped by its size check (W04-B2 gone), and more than 78 links are dropped with a line. Absent
  until their milestones: prison `0x0F6A`, Guild Tournament `0x0F6C`, the chat ban, the chat-title counter `0x6006`
  and the GM colour bit of `0x200D`.

  `0x0C33` asks Login for a login token and answers `0x0C34` (flow: `docs/technical/flows/return-to-world-list.md`).
  `0x0C18` with type 0 closes the connection. `0x0C18` with type 1 (back to the character list) asks the Zone
  connection to leave the world and waits for its save (`Cluster.Sessions.leave_world/1`); the client then asks for
  the list with `0x0C1F`. Other types are ignored. A closed socket ends the process and with it the session, once
  (W05-B25, W05-B9 and P02-B35 are link effects that do not exist here); the Zone connection then saves and closes
  (flow: `docs/technical/flows/leave-world.md`).

  A kick (`&kickout`, flow: `docs/technical/flows/gm-commands.md`) comes as `{:cluster, {:kick, code}}` from a GM's
  Zone connection that found the session by character name (`Cluster.Sessions.find_character/2`), so it reaches the
  session on any node, also while its player is between two maps. A session with a character in the world sends
  `0x0C17 {0x068B}`, drops an open reservation, leaves the character group (a second kick finds nobody) and tells its
  Zone connection, which saves and closes (`Cluster.Sessions.kicked/1`). The session stays open: the client closes
  it with `0x0C18 {0}`. A later `0x1801` of the player finds no ticket (`0x1804 {0x141}`).
  """

  @behaviour Net.Handler

  alias Proto.Packets.ActSomeonewhisperCmd
  alias Proto.Packets.ActWhisperfailAck
  alias Proto.Packets.ActWhisperReq
  alias Proto.Packets.ActWhispersuccessAck
  alias Proto.Packets.AvatarCreatefailAck
  alias Proto.Packets.AvatarCreatesuccAck
  alias Proto.Packets.AvatarCreateReq
  alias Proto.Packets.AvatarEraseReq
  alias Proto.Packets.AvatarErasefailAck
  alias Proto.Packets.AvatarErasesuccAck
  alias Proto.Packets.AvatarRenameAck
  alias Proto.Packets.AvatarRenameReq
  alias Proto.Packets.CharLoginAck
  alias Proto.Packets.CharLoginfailAck
  alias Proto.Packets.CharLoginReq
  alias Proto.Packets.CharOptionGetShortcutsizeReq
  alias Proto.Packets.CharOptionGetWindowposReq
  alias Proto.Packets.CharTutorialPopupAck
  alias Proto.Packets.CharTutorialPopupReq
  alias Proto.Packets.MiscGametimeAck
  alias Proto.Packets.KqListRefreshReq
  alias Proto.Packets.KqListTimeAck
  alias Proto.Packets.MapLinkendClientCmd
  alias Proto.Packets.MiscGametimeReq
  alias Proto.Packets.MiscServerTimeNotifyCmd
  alias Proto.Packets.PrisonGetReq
  alias Proto.Packets.UserAvatarListReq
  alias Proto.Packets.UserConnectcutCmd
  alias Proto.Packets.UserConnectionChangeCharIdAck
  alias Proto.Packets.UserConnectionChangeCharIdReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserLoginworldfailAck
  alias Proto.Packets.UserNormallogoutCmd
  alias Proto.Packets.UserWillWorldSelectAck
  alias Proto.Packets.UserWillWorldSelectReq

  @enforce_keys [:worlds]
  defstruct [:worlds, :world_no, :handle] ++
              [step: :login, user_no: :none, user_name: :none, tutorial: :none, reservation: :none, zone: :none] ++
              [character: :none] ++
              [kq_time_sent?: false, burst_sent?: false]

  @type reservation ::
          %{kind: :first_entry, character_id: pos_integer(), name: binary(), map: String.t(), node: node()}
          | %{
              kind: :map_change,
              character_id: pos_integer(),
              name: binary(),
              map: String.t(),
              node: node(),
              x: non_neg_integer(),
              y: non_neg_integer(),
              player: struct()
            }

  @type t :: %__MODULE__{
          worlds: [Cluster.Registry.world_id()],
          world_no: Cluster.Registry.world_id() | nil,
          handle: 0..0xFFFF | nil,
          step: :login | :open,
          user_no: :none | pos_integer(),
          user_name: :none | String.t(),
          tutorial: :none | Persistence.character(),
          reservation: :none | reservation(),
          zone: :none | pid(),
          character: :none | binary(),
          kq_time_sent?: boolean(),
          burst_sent?: boolean()
        }

  # above it the relayed 0x200D can exceed the frame limit of Net.Connection
  @max_item_links 78

  @impl Net.Handler
  def init(settings), do: %__MODULE__{worlds: Enum.map(settings.world, & &1.number)}

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :login} = state, %UserLoginworldReq{user_name: name, validate: validate}),
    do: {state, [{:perform, {:take_login, state.worlds, name, validate}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet), do: {state, [{:close, :info, "wrong first packet"}]}

  def handle_packet(%__MODULE__{step: :open} = state, %UserAvatarListReq{}),
    do: {state, [{:perform, {:list_characters, state.world_no, state.user_no}}]}

  def handle_packet(%__MODULE__{step: :open} = state, %MiscGametimeReq{}), do: {state, [{:perform, :game_time}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %UserWillWorldSelectReq{})
      when is_integer(user_no),
      do: {state, [{:perform, {:create_token, user_no, state.user_name}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %AvatarCreateReq{} = req)
      when is_integer(user_no),
      do: {state, [{:perform, {:create_character, state.world_no, user_no, req}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %AvatarEraseReq{slot: slot})
      when is_integer(user_no),
      do: {state, [{:perform, {:delete_character, state.world_no, user_no, slot}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %AvatarRenameReq{slot: slot, name: name})
      when is_integer(user_no),
      do: {state, [{:perform, {:rename_character, state.world_no, user_no, slot, name}}]}

  # A deferral until the item milestone grants rename rights; P02-B34 fixed: the slot of the request.
  def handle_packet(%__MODULE__{step: :open} = state, %UserConnectionChangeCharIdReq{slot: slot, name: name}),
    do: {state, [{:send, %UserConnectionChangeCharIdAck{error: 0x20C3, slot: slot, name: name}}]}

  def handle_packet(%__MODULE__{step: :open} = state, %UserNormallogoutCmd{logout_type: 0}),
    do: {state, [{:close, :debug, "client logged out"}]}

  def handle_packet(%__MODULE__{step: :open, zone: zone} = state, %UserNormallogoutCmd{logout_type: 1})
      when is_pid(zone),
      do: {state, [{:perform, {:leave_world, zone}}]}

  # Back to the character list between two maps: the map-login ticket is void (the player is saved already).
  def handle_packet(%__MODULE__{step: :open, reservation: %{}} = state, %UserNormallogoutCmd{logout_type: 1}),
    do: {%{state | reservation: :none}, [{:log, :info, "map-login ticket dropped: back to the character list"}]}

  # As the original's "PlayingCharNo" refusal: the session already has a character in the world.
  def handle_packet(%__MODULE__{step: :open, zone: zone} = state, %CharLoginReq{}) when is_pid(zone),
    do: {state, [{:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %CharLoginReq{slot: slot})
      when is_integer(user_no) and slot > 5,
      do: {state, [{:send, %CharLoginfailAck{error: 0x143}}]}

  # A new 0x1001 voids an open reservation and an open question.
  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %CharLoginReq{slot: slot})
      when is_integer(user_no) do
    leave = if is_binary(state.character), do: [{:perform, {:leave_world, state.world_no, state.character}}], else: []

    {%{state | tutorial: :none, reservation: :none, character: :none, burst_sent?: false},
     leave ++ [{:perform, {:select_character, state.world_no, user_no, slot}}]}
  end

  def handle_packet(%__MODULE__{step: :open, tutorial: %{}} = state, %CharTutorialPopupAck{is_skip: 0}),
    do: {%{state | tutorial: :none}, [{:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no, tutorial: %{} = c} = state, %CharTutorialPopupAck{})
      when is_integer(user_no),
      do: {%{state | tutorial: :none}, [{:perform, {:skip_tutorial, state.world_no, user_no, c}}]}

  def handle_packet(%__MODULE__{step: :open} = state, %CharOptionGetShortcutsizeReq{}),
    do: {state, [{:send, WorldManager.Placeholders.shortcut_size()}]}

  def handle_packet(%__MODULE__{step: :open} = state, %CharOptionGetWindowposReq{}),
    do: {state, [{:send, WorldManager.Placeholders.window_pos()}]}

  def handle_packet(%__MODULE__{step: :open} = state, %PrisonGetReq{}),
    do: {state, [{:send, WorldManager.Placeholders.prison()}]}

  # Only the first 0x581B of a session gets the server time; the Kingdom Quest list 0x581D is milestone 10.
  def handle_packet(%__MODULE__{step: :open, kq_time_sent?: false} = state, %KqListRefreshReq{}),
    do: {%{state | kq_time_sent?: true}, [{:perform, :kq_list_time}]}

  def handle_packet(%__MODULE__{step: :open} = state, %KqListRefreshReq{}), do: {state, []}

  def handle_packet(%__MODULE__{step: :open, character: talker} = state, %ActWhisperReq{item_link_count: n})
      when is_binary(talker) and n > @max_item_links,
      do: {state, [{:log, :info, "whisper dropped: #{n} item links"}]}

  # W04-B4 fixed: the count byte is 0
  def handle_packet(%__MODULE__{step: :open, character: talker} = state, %ActWhisperReq{content: ""} = req)
      when is_binary(talker),
      do: {state, [{:send, %ActWhispersuccessAck{item_link_count: 0, receiver: req.receiver, content: "", links: ""}}]}

  def handle_packet(%__MODULE__{step: :open, character: talker} = state, %ActWhisperReq{} = req)
      when is_binary(talker),
      do: {state, [{:perform, {:whisper, state.world_no, talker, req}}]}

  def handle_packet(%__MODULE__{step: :open} = state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:login_taken, {:ok, world_no, user_no, name, handle}}),
    do:
      {%{state | step: :open, world_no: world_no, user_no: user_no, user_name: name, handle: handle},
       [{:perform, {:list_characters, world_no, user_no}}]}

  def handle_info(state, {:token_created, {:ok, token}}),
    do: {state, [{:send, %UserWillWorldSelectAck{error: 0x1E58, otp: token}}]}

  def handle_info(state, {:token_created, {:error, :pending}}),
    do: {state, [{:send, %UserWillWorldSelectAck{error: 0x1E5B, otp: ""}}]}

  def handle_info(state, {:login_taken, :error}),
    do:
      {state,
       [{:send, %UserLoginworldfailAck{error: 0x44}}, {:close, :info, "world login refused, no matching reservation"}]}

  def handle_info(state, {:login_taken, :timeout}),
    do:
      {state,
       [
         {:send, %UserLoginworldfailAck{error: 0x46}},
         {:close, :error, "world login refused, the old session did not end in time"}
       ]}

  def handle_info(state, {:left_world, :ok}), do: {%{state | zone: :none}, []}

  # The zone stays set: 0x1001 answers 0x145 until its :DOWN.
  def handle_info(state, {:left_world, {:error, :timeout}}),
    do: {state, [{:log, :error, "the Zone connection did not confirm the leave within 5 s"}]}

  def handle_info(state, {:characters, {:ok, characters}}),
    do:
      {state,
       [
         {:send,
          %UserLoginworldAck{
            worldmanager: state.handle,
            avatars: Enum.map(characters, &WorldManager.Avatar.from_character/1)
          }}
       ]}

  # W05-B10 fixed: one close
  def handle_info(state, {:characters, {:error, :database}}),
    do:
      {state,
       [{:send, %UserLoginworldfailAck{error: 0x46}}, {:close, :warning, "character list failed, database failure"}]}

  def handle_info(state, {:character_created, {:ok, character}}),
    do: {state, [{:send, %AvatarCreatesuccAck{avatars: [WorldManager.Avatar.created(character)]}}]}

  def handle_info(state, {:character_created, {:error, reason}}),
    do: {state, [{:send, %AvatarCreatefailAck{error: WorldManager.CharacterCreate.code(reason)}}]}

  def handle_info(state, {:character_deleted, slot, :ok}), do: {state, [{:send, %AvatarErasesuccAck{slot: slot}}]}

  def handle_info(state, {:character_deleted, _slot, {:error, reason}}),
    do: {state, [{:send, %AvatarErasefailAck{error: erase_code(reason)}}]}

  def handle_info(state, {:character_renamed, slot, name, :ok}),
    do: {state, [{:send, %AvatarRenameAck{slot: slot, name: name, error: 0xD0}}]}

  # One code for every refusal: the client has one text ("The name cannot be used."). P02-B42 fixed: a taken name is refused.
  def handle_info(state, {:character_renamed, slot, name, {:error, reason}})
      when reason in [:name, :not_found, :name_taken, :database],
      do: {state, [{:send, %AvatarRenameAck{slot: slot, name: name, error: 0xD1}}]}

  def handle_info(state, {:game_time, {hour, minute, second}}),
    do: {state, [{:send, %MiscGametimeAck{hour: hour, minute: minute, second: second}}]}

  def handle_info(state, {:character_selected, {:ok, %{tutorial_state: 0} = c}}),
    do: {%{state | tutorial: c}, [{:send, %CharTutorialPopupReq{unused: 0}}]}

  def handle_info(state, {:character_selected, {:ok, c}}), do: {state, [{:perform, {:find_zone, state.world_no, c}}]}

  # W01-B6 kept: the original answers an empty slot with 0x31EB.
  def handle_info(state, {:character_selected, {:error, :empty_slot}}),
    do: {state, [{:send, %CharLoginfailAck{error: 0x31EB}}]}

  # The line comes before the answer: a reader of the answer (a test, an administrator) finds the line already written.
  def handle_info(state, {:character_selected, {:error, :database}}),
    do:
      {state, [{:log, :warning, "character login failed, database failure"}, {:send, %CharLoginfailAck{error: 0x145}}]}

  # The client enters the world only after these three pushes (its gate FUN_00477470); the original sends them after
  # every 0x1003 and not at a map change.
  def handle_info(state, {:zone_found, c, {:ok, zone}}),
    do:
      {%{
         state
         | reservation: %{kind: :first_entry, character_id: c.id, name: c.name, map: c.login_map, node: zone.node}
       },
       [
         {:send, %CharLoginAck{zone_ip: zone.host, zone_port: zone.port}},
         {:send, WorldManager.Placeholders.shortcut_data()},
         {:send, WorldManager.Placeholders.key_map()},
         {:send, WorldManager.Placeholders.game_option()}
       ]}

  def handle_info(state, {:zone_found, c, :error}),
    do:
      {state,
       [
         {:log, :info, "character login refused: map #{c.login_map} is not running"},
         {:send, %CharLoginfailAck{error: 0x145}}
       ]}

  # P02-B33 fixed narrowly: a skip enters the world on the stored map.
  def handle_info(state, {:tutorial_skipped, c, :ok}), do: {state, [{:perform, {:find_zone, state.world_no, c}}]}

  def handle_info(state, {:tutorial_skipped, _c, {:error, :not_found}}),
    do: {state, [{:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_info(state, {:tutorial_skipped, _c, {:error, :database}}),
    do: {state, [{:log, :warning, "tutorial skip failed, database failure"}, {:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_info(state, {:zone_connected, pid}), do: {%{state | zone: pid}, []}
  def handle_info(%__MODULE__{zone: pid} = state, {:down, pid}), do: {%{state | zone: :none}, []}
  def handle_info(state, {:down, _other}), do: {state, []}

  def handle_info(state, {:cluster, :map_login_done}), do: {state, [{:perform, :map_login_done}]}

  def handle_info(state, {:kq_list_time, unix, local}),
    do: {state, [{:send, %KqListTimeAck{server_time: unix, tm: WorldManager.ServerTime.tm(local)}}]}

  # After a map change the capture repeats only 0x5826 and 0x182A (walk-run-portals 324/325).
  def handle_info(%__MODULE__{burst_sent?: true} = state, {:map_login_done, _unix, _local}),
    do: {state, [{:send, WorldManager.Placeholders.kq_joining_alarm()}, {:send, %MapLinkendClientCmd{unused: 0}}]}

  def handle_info(state, {:map_login_done, unix, local}),
    do:
      {%{state | burst_sent?: true},
       [
         {:send, WorldManager.Placeholders.guild_academy()},
         {:send, WorldManager.Placeholders.guild()},
         {:send, WorldManager.Placeholders.holy_promise()},
         {:send, WorldManager.Placeholders.kq_joining_alarm()},
         {:send, WorldManager.Placeholders.newbie_guide()},
         {:send,
          %MiscServerTimeNotifyCmd{
            tm: WorldManager.ServerTime.tm(local),
            time_zone: WorldManager.ServerTime.time_zone(unix, local)
          }},
         {:send, %MapLinkendClientCmd{unused: 0}}
       ]}

  def handle_info(state, :left_world), do: {state, []}

  def handle_info(state, {:whisper_failed, code, receiver}),
    do: {state, [{:send, %ActWhisperfailAck{error: code, receiver: receiver}}]}

  def handle_info(state, :whisper_passed_on), do: {state, []}

  def handle_info(%__MODULE__{character: name} = state, {:cluster, {:whisper, from, w}}) when is_binary(name),
    do:
      {state,
       [
         {:send,
          %ActSomeonewhisperCmd{
            item_link_count: w.item_link_count,
            talker: w.talker,
            flag: 0,
            content: w.content,
            links: w.links
          }},
         {:perform, {:whisper_delivered, from, %{w | receiver: name}}}
       ]}

  # The receiver left the world between the lookup and the delivery.
  def handle_info(state, {:cluster, {:whisper, from, w}}),
    do: {state, [{:perform, {:whisper_refused, from, w.receiver}}]}

  def handle_info(state, {:cluster, {:whisper_delivered, w}}),
    do:
      {state,
       [
         {:send,
          %ActWhispersuccessAck{
            item_link_count: w.item_link_count,
            receiver: w.receiver,
            content: w.content,
            links: w.links
          }}
       ]}

  def handle_info(state, {:cluster, {:whisper_refused, receiver}}),
    do: {state, [{:send, %ActWhisperfailAck{error: 0x0F69, receiver: receiver}}]}

  def handle_info(%__MODULE__{character: name} = state, {:cluster, {:kick, code}}) when is_binary(name) do
    zone = if is_pid(state.zone), do: [{:perform, {:kick_zone, state.zone}}], else: []

    {%{state | reservation: :none, character: :none},
     [
       {:log, :info, "kicked: character #{inspect(name)}"},
       {:send, %UserConnectcutCmd{error: code}},
       {:perform, {:leave_world, state.world_no, name}}
     ] ++ zone}
  end

  def handle_info(state, {:cluster, {:kick, _code}}), do: {state, []}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, {:close, :info, "session replaced"}]}

  # A Zone connection redeems the map-login ticket (Cluster.Sessions.redeem/2); only a success uses it up.
  @impl Net.Handler
  def handle_call(
        %__MODULE__{reservation: %{kind: :first_entry, name: name, node: node} = r} = state,
        {:redeem, name, node, zone_pid}
      ) do
    entry = %{
      kind: :first_entry,
      world_no: state.world_no,
      user_no: state.user_no,
      character_id: r.character_id,
      name: name,
      map: r.map
    }

    {{:ok, entry}, %{state | reservation: :none, character: name},
     [{:perform, {:enter_world, state.world_no, name, zone_pid}}]}
  end

  # The character is in the world already (Cluster.Sessions.enter_world/2 ran at its first entry).
  def handle_call(
        %__MODULE__{reservation: %{kind: :map_change, name: name, node: node} = r} = state,
        {:redeem, name, node, zone_pid}
      ) do
    entry = %{
      kind: :map_change,
      world_no: state.world_no,
      user_no: state.user_no,
      character_id: r.character_id,
      name: name,
      map: r.map,
      x: r.x,
      y: r.y,
      player: r.player
    }

    {{:ok, entry}, %{state | reservation: :none}, [{:perform, {:watch_zone, zone_pid}}]}
  end

  def handle_call(%__MODULE__{reservation: %{name: name}} = state, {:redeem, name, _node, _zone_pid}),
    do: {{:error, :wrong_node}, state, []}

  def handle_call(%__MODULE__{reservation: %{}} = state, {:redeem, _name, _node, _zone_pid}),
    do: {{:error, :wrong_character}, state, []}

  def handle_call(%__MODULE__{reservation: :none} = state, {:redeem, _name, _node, _zone_pid}),
    do: {{:error, :no_ticket}, state, []}

  # The old Zone connection of a map change parks its player here (Cluster.Sessions.reserve/2); only the session's
  # current Zone connection can.
  def handle_call(%__MODULE__{character: name, handle: handle, zone: zone} = state, {:reserve, zone, r})
      when is_binary(name) and is_pid(zone) do
    reservation = %{
      kind: :map_change,
      character_id: r.character_id,
      name: name,
      map: r.map,
      node: r.node,
      x: r.x,
      y: r.y,
      player: r.player
    }

    # no character is on a map now, so 0x1001 voids the reservation instead of answering 0x145
    {{:ok, handle}, %{state | reservation: reservation, zone: :none}, []}
  end

  def handle_call(state, {:reserve, _zone, _r}), do: {{:error, :no_session}, state, []}

  @impl Net.Handler
  def perform({:create_token, user_no, user_name}),
    do: {:token_created, Cluster.Login.create_token(user_no, user_name)}

  def perform({:take_login, worlds, name, validate}) do
    taken =
      Enum.find_value(worlds, fn world_no ->
        case WorldManager.World.take_login(world_no, name, validate) do
          {:ok, user_no, handle} -> {world_no, user_no, handle}
          :error -> nil
        end
      end)

    case taken do
      {world_no, user_no, handle} ->
        case Cluster.Sessions.take_over(user_no) do
          :ok ->
            :ok = Cluster.Sessions.register_handle(handle)
            :ok = Cluster.Registry.join_players(world_no, self())
            {:login_taken, {:ok, world_no, user_no, name, handle}}

          {:error, :timeout} ->
            {:login_taken, :timeout}
        end

      nil ->
        {:login_taken, :error}
    end
  end

  def perform({:leave_world, zone}), do: {:left_world, Cluster.Sessions.leave_world(zone)}

  def perform({:list_characters, world_no, user_no}),
    do: {:characters, Persistence.list_characters(world_no, user_no)}

  def perform({:create_character, world_no, user_no, req}),
    do: {:character_created, WorldManager.CharacterCreate.run(world_no, user_no, req)}

  def perform({:delete_character, world_no, user_no, slot}),
    do: {:character_deleted, slot, Persistence.delete_character(world_no, user_no, slot)}

  def perform({:rename_character, world_no, user_no, slot, name}) do
    result =
      if WorldManager.CharacterCreate.valid_name?(name, 16),
        do: Persistence.rename_character(world_no, user_no, slot, name),
        else: {:error, :name}

    {:character_renamed, slot, name, result}
  end

  def perform({:select_character, world_no, user_no, slot}) do
    result =
      with {:ok, characters} <- Persistence.list_characters(world_no, user_no) do
        case Enum.find(characters, &(&1.slot == slot)) do
          nil -> {:error, :empty_slot}
          c -> {:ok, c}
        end
      end

    {:character_selected, result}
  end

  def perform({:find_zone, world_no, c}), do: {:zone_found, c, WorldManager.World.zone_of(world_no, c.login_map)}

  def perform({:skip_tutorial, world_no, user_no, c}),
    do: {:tutorial_skipped, c, Persistence.skip_tutorial(world_no, user_no, c.slot)}

  def perform({:enter_world, world_no, name, pid}) do
    :ok = Cluster.Sessions.enter_world(world_no, name)
    _ = Process.monitor(pid)
    {:zone_connected, pid}
  end

  def perform({:watch_zone, pid}) do
    _ = Process.monitor(pid)
    {:zone_connected, pid}
  end

  def perform({:leave_world, world_no, name}) do
    :ok = Cluster.Sessions.leave_world(world_no, name)
    :left_world
  end

  def perform({:kick_zone, pid}) do
    :ok = Cluster.Sessions.kicked(pid)
    :left_world
  end

  def perform({:whisper, world_no, talker, req}) do
    case Cluster.Sessions.find_character(world_no, req.receiver) do
      :error ->
        {:whisper_failed, 0x0F69, req.receiver}

      # W04-B5 kept: the client shows nothing for 0x0F6B
      {:ok, _pid} when byte_size(req.content) > 128 ->
        {:whisper_failed, 0x0F6B, req.receiver}

      {:ok, pid} ->
        whisper = %{
          talker: talker,
          receiver: req.receiver,
          item_link_count: req.item_link_count,
          content: req.content,
          links: req.links
        }

        :ok = Cluster.Sessions.whisper(pid, whisper)
        :whisper_passed_on
    end
  end

  def perform({:whisper_delivered, from, whisper}) do
    :ok = Cluster.Sessions.whisper_delivered(from, whisper)
    :whisper_passed_on
  end

  def perform({:whisper_refused, from, receiver}) do
    :ok = Cluster.Sessions.whisper_refused(from, receiver)
    :whisper_passed_on
  end

  def perform(:kq_list_time) do
    unix = Clock.system_time(:second)
    {:kq_list_time, unix, Clock.local_time(unix)}
  end

  def perform(:map_login_done) do
    unix = Clock.system_time(:second)
    {:map_login_done, unix, Clock.local_time(unix)}
  end

  def perform(:game_time) do
    {_date, time} = Clock.local_time(Clock.system_time(:second))
    {:game_time, time}
  end

  # W01-B3 and D02-B3 kept: the client has one text for every code but 0xC7, so no neutral code exists.
  defp erase_code(:guild_master), do: 0xC7
  defp erase_code(:not_found), do: 0xC6
  defp erase_code(:database), do: 0xC6
end
