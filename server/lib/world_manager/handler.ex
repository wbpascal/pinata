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
  node that runs the character's stored map and answers `0x1003` with that node's address, or `0x1002`. A character
  with tutorial state 0 is first asked `0x1110`; a skip (`0x1111`) saves state 2 and goes on. The Zone redeems the
  ticket with `handle_call/2` on `0x1801`; from then on the session monitors the Zone connection (flow:
  `docs/technical/flows/enter-world.md`).

  `0x0C33` asks Login for a login token and answers `0x0C34` (flow: `docs/technical/flows/return-to-world-list.md`).
  `0x0C18` with type 0 closes the connection; other types are ignored for now. A closed socket ends the process and
  with it the session, once (W05-B25, W05-B9 and P02-B35 are link effects that do not exist here).
  """

  @behaviour Net.Handler

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
  alias Proto.Packets.CharTutorialPopupAck
  alias Proto.Packets.CharTutorialPopupReq
  alias Proto.Packets.MiscGametimeAck
  alias Proto.Packets.MiscGametimeReq
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
              [step: :login, user_no: :none, user_name: :none, tutorial: :none, reservation: :none, zone: :none]

  @type reservation :: %{character_id: pos_integer(), name: binary(), map: String.t(), node: node()}

  @type t :: %__MODULE__{
          worlds: [Cluster.Registry.world_id()],
          world_no: Cluster.Registry.world_id() | nil,
          handle: 0..0xFFFF | nil,
          step: :login | :open,
          user_no: :none | pos_integer(),
          user_name: :none | String.t(),
          tutorial: :none | Persistence.character(),
          reservation: :none | reservation(),
          zone: :none | pid()
        }

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

  # As the original's "PlayingCharNo" refusal: the session already has a character in the world.
  def handle_packet(%__MODULE__{step: :open, zone: zone} = state, %CharLoginReq{}) when is_pid(zone),
    do: {state, [{:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %CharLoginReq{slot: slot})
      when is_integer(user_no) and slot > 5,
      do: {state, [{:send, %CharLoginfailAck{error: 0x143}}]}

  # A new 0x1001 voids an open reservation and an open question.
  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %CharLoginReq{slot: slot})
      when is_integer(user_no),
      do:
        {%{state | tutorial: :none, reservation: :none},
         [{:perform, {:select_character, state.world_no, user_no, slot}}]}

  def handle_packet(%__MODULE__{step: :open, tutorial: %{}} = state, %CharTutorialPopupAck{is_skip: 0}),
    do: {%{state | tutorial: :none}, [{:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no, tutorial: %{} = c} = state, %CharTutorialPopupAck{})
      when is_integer(user_no),
      do: {%{state | tutorial: :none}, [{:perform, {:skip_tutorial, state.world_no, user_no, c}}]}

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

  def handle_info(state, {:character_selected, {:error, :database}}),
    do:
      {state, [{:send, %CharLoginfailAck{error: 0x145}}, {:log, :warning, "character login failed, database failure"}]}

  def handle_info(state, {:zone_found, c, {:ok, zone}}),
    do:
      {%{state | reservation: %{character_id: c.id, name: c.name, map: c.login_map, node: zone.node}},
       [{:send, %CharLoginAck{zone_ip: zone.host, zone_port: zone.port}}]}

  def handle_info(state, {:zone_found, c, :error}),
    do:
      {state,
       [
         {:send, %CharLoginfailAck{error: 0x145}},
         {:log, :info, "character login refused: map #{c.login_map} is not running"}
       ]}

  # P02-B33 fixed narrowly: a skip enters the world on the stored map.
  def handle_info(state, {:tutorial_skipped, c, :ok}), do: {state, [{:perform, {:find_zone, state.world_no, c}}]}

  def handle_info(state, {:tutorial_skipped, _c, {:error, :not_found}}),
    do: {state, [{:send, %CharLoginfailAck{error: 0x145}}]}

  def handle_info(state, {:tutorial_skipped, _c, {:error, :database}}),
    do: {state, [{:send, %CharLoginfailAck{error: 0x145}}, {:log, :warning, "tutorial skip failed, database failure"}]}

  def handle_info(state, {:zone_connected, pid}), do: {%{state | zone: pid}, []}
  def handle_info(%__MODULE__{zone: pid} = state, {:down, pid}), do: {%{state | zone: :none}, []}
  def handle_info(state, {:down, _other}), do: {state, []}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, {:close, :info, "session replaced"}]}

  # A Zone connection redeems the map-login ticket (Cluster.Sessions.redeem/2); only a success uses it up.
  @impl Net.Handler
  def handle_call(%__MODULE__{reservation: %{name: name, node: node} = r} = state, {:redeem, name, node, zone_pid}) do
    entry = %{
      kind: :first_entry,
      world_no: state.world_no,
      user_no: state.user_no,
      character_id: r.character_id,
      name: name,
      map: r.map
    }

    {{:ok, entry}, %{state | reservation: :none}, [{:perform, {:watch_zone, zone_pid}}]}
  end

  def handle_call(%__MODULE__{reservation: %{name: name}} = state, {:redeem, name, _node, _zone_pid}),
    do: {{:error, :wrong_node}, state, []}

  def handle_call(%__MODULE__{reservation: %{}} = state, {:redeem, _name, _node, _zone_pid}),
    do: {{:error, :wrong_character}, state, []}

  def handle_call(%__MODULE__{reservation: :none} = state, {:redeem, _name, _node, _zone_pid}),
    do: {{:error, :no_ticket}, state, []}

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
        :ok = Cluster.Sessions.take_over(user_no)
        :ok = Cluster.Sessions.register_handle(handle)
        :ok = Cluster.Registry.join_players(world_no, self())
        {:login_taken, {:ok, world_no, user_no, name, handle}}

      nil ->
        {:login_taken, :error}
    end
  end

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

  def perform({:watch_zone, pid}) do
    _ = Process.monitor(pid)
    {:zone_connected, pid}
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
