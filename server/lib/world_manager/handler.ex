defmodule WorldManager.Handler do
  @moduledoc """
  Packet handler of the WorldManager part: the login of a client that was handed over by Login (`0x0C0F`; flow:
  `docs/technical/flows/world-select.md`).

  The login is accepted only for a reservation with the same key and the same user name (W01-B1 fixed). An accepted
  connection becomes the session of the account and counts as a player of the world. It then gets the character list
  `0x0C14` (also on `0x0C1F`) and answers `0x080D` with `0x080E` (flow: `docs/technical/flows/character-list.md`).
  """

  @behaviour Net.Handler

  alias Proto.Packets.MiscGametimeAck
  alias Proto.Packets.MiscGametimeReq
  alias Proto.Packets.UserAvatarListReq
  alias Proto.Packets.UserConnectcutCmd
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserLoginworldfailAck

  @enforce_keys [:worlds]
  defstruct [:worlds, :world_no, :user_no, :handle, step: :login]

  @type t :: %__MODULE__{
          worlds: [Cluster.Registry.world_id()],
          world_no: Cluster.Registry.world_id() | nil,
          user_no: pos_integer() | nil,
          handle: 0..0xFFFF | nil,
          step: :login | :open
        }

  @impl Net.Handler
  def init(settings), do: %__MODULE__{worlds: Enum.map(settings.world, & &1.number)}

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :login} = state, %UserLoginworldReq{user_name: name, validate: validate}),
    do: {state, [{:perform, {:take_login, state.worlds, name, validate}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet), do: {state, [:close]}

  def handle_packet(%__MODULE__{step: :open} = state, %UserAvatarListReq{}),
    do: {state, [{:perform, {:list_characters, state.world_no, state.user_no}}]}

  def handle_packet(%__MODULE__{step: :open} = state, %MiscGametimeReq{}), do: {state, [{:perform, :game_time}]}
  def handle_packet(%__MODULE__{step: :open} = state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:login_taken, {:ok, world_no, user_no, handle}}),
    do:
      {%{state | step: :open, world_no: world_no, user_no: user_no, handle: handle},
       [{:perform, {:list_characters, world_no, user_no}}]}

  def handle_info(state, {:login_taken, :error}), do: {state, [{:send, %UserLoginworldfailAck{error: 0x44}}, :close]}

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
    do: {state, [{:send, %UserLoginworldfailAck{error: 0x46}}, :close]}

  def handle_info(state, {:game_time, {hour, minute, second}}),
    do: {state, [{:send, %MiscGametimeAck{hour: hour, minute: minute, second: second}}]}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, :close]}

  @impl Net.Handler
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
        :ok = Cluster.Registry.join_players(world_no, self())
        {:login_taken, {:ok, world_no, user_no, handle}}

      nil ->
        {:login_taken, :error}
    end
  end

  def perform({:list_characters, world_no, user_no}),
    do: {:characters, Persistence.list_characters(world_no, user_no)}

  def perform(:game_time) do
    {_date, time} = Clock.local_time(Clock.system_time(:second))
    {:game_time, time}
  end
end
