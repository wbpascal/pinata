defmodule WorldManager.Handler do
  @moduledoc """
  Packet handler of the WorldManager part: the login of a client that was handed over by Login (`0x0C0F`; flow:
  `docs/technical/flows/world-select.md`).

  The login is accepted only for a reservation with the same key and the same user name (W01-B1 fixed). An accepted
  connection becomes the session of the account and counts as a player of the world. Nothing is sent on success yet;
  the character list issue adds `0x0C14`.

  `0x0C33` asks Login for a login token and answers `0x0C34` (flow: `docs/technical/flows/return-to-world-list.md`).
  `0x0C18` with type 0 closes the connection; other types are ignored for now. A closed socket ends the process and
  with it the session, once (W05-B25, W05-B9 and P02-B35 are link effects that do not exist here).
  """

  @behaviour Net.Handler

  alias Proto.Packets.UserConnectcutCmd
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserLoginworldfailAck
  alias Proto.Packets.UserNormallogoutCmd
  alias Proto.Packets.UserWillWorldSelectAck
  alias Proto.Packets.UserWillWorldSelectReq

  @enforce_keys [:worlds]
  defstruct [:worlds, step: :login, user_no: :none, user_name: :none]

  @type t :: %__MODULE__{
          worlds: [Cluster.Registry.world_id()],
          step: :login | :open,
          user_no: :none | pos_integer(),
          user_name: :none | String.t()
        }

  @impl Net.Handler
  def init(settings), do: %__MODULE__{worlds: Enum.map(settings.world, & &1.number)}

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :login} = state, %UserLoginworldReq{user_name: name, validate: validate}),
    do: {state, [{:perform, {:take_login, state.worlds, name, validate}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet), do: {state, [:close]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %UserWillWorldSelectReq{})
      when is_integer(user_no),
      do: {state, [{:perform, {:create_token, user_no, state.user_name}}]}

  def handle_packet(%__MODULE__{step: :open} = state, %UserNormallogoutCmd{logout_type: 0}), do: {state, [:close]}
  def handle_packet(%__MODULE__{step: :open} = state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:login_taken, {:ok, user_no, name}}),
    do: {%{state | step: :open, user_no: user_no, user_name: name}, []}

  def handle_info(state, {:token_created, {:ok, token}}),
    do: {state, [{:send, %UserWillWorldSelectAck{error: 0x1E58, otp: token}}]}

  def handle_info(state, {:token_created, {:error, :pending}}),
    do: {state, [{:send, %UserWillWorldSelectAck{error: 0x1E5B, otp: ""}}]}

  def handle_info(state, {:login_taken, :error}), do: {state, [{:send, %UserLoginworldfailAck{error: 0x44}}, :close]}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, :close]}

  @impl Net.Handler
  def perform({:create_token, user_no, user_name}),
    do: {:token_created, Cluster.Login.create_token(user_no, user_name)}

  def perform({:take_login, worlds, name, validate}) do
    taken =
      Enum.find_value(worlds, fn world_no ->
        case WorldManager.World.take_login(world_no, name, validate) do
          {:ok, user_no} -> {world_no, user_no}
          :error -> nil
        end
      end)

    case taken do
      {world_no, user_no} ->
        :ok = Cluster.Sessions.take_over(user_no)
        :ok = Cluster.Registry.join_players(world_no, self())
        {:login_taken, {:ok, user_no, name}}

      nil ->
        {:login_taken, :error}
    end
  end
end
