defmodule WorldManager.Handler do
  @moduledoc """
  Packet handler of the WorldManager part: the login of a client that was handed over by Login (`0x0C0F`; flow:
  `docs/technical/flows/world-select.md`).

  The login is accepted only for a reservation with the same key and the same user name (W01-B1 fixed). An accepted
  connection becomes the session of the account and counts as a player of the world. Nothing is sent on success yet;
  the character list issue adds `0x0C14`.
  """

  @behaviour Net.Handler

  alias Proto.Packets.UserConnectcutCmd
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserLoginworldfailAck

  @enforce_keys [:worlds]
  defstruct [:worlds, step: :login]

  @type t :: %__MODULE__{worlds: [Cluster.Registry.world_id()], step: :login | :open}

  @impl Net.Handler
  def init(settings), do: %__MODULE__{worlds: Enum.map(settings.world, & &1.number)}

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :login} = state, %UserLoginworldReq{user_name: name, validate: validate}),
    do: {state, [{:perform, {:take_login, state.worlds, name, validate}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet), do: {state, [:close]}
  def handle_packet(%__MODULE__{step: :open} = state, _packet), do: {state, []}

  @impl Net.Handler
  def handle_info(state, {:login_taken, :ok}), do: {%{state | step: :open}, []}
  def handle_info(state, {:login_taken, :error}), do: {state, [{:send, %UserLoginworldfailAck{error: 0x44}}, :close]}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, :close]}

  @impl Net.Handler
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
        {:login_taken, :ok}

      nil ->
        {:login_taken, :error}
    end
  end
end
