defmodule Login.Handler do
  @moduledoc """
  Packet handler of the Login part: version check, account login and the world list
  (flow: `docs/technical/flows/login.md`).

  `handle_packet/2` and `handle_info/2` are pure. Database and `Cluster` work is a `{:perform, request}` effect
  that `perform/1` carries out; its result comes back through `handle_info/2`.
  """

  @behaviour Net.Handler

  alias Proto.Packets.UserClientRightversionCheckAck
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserClientWrongversionCheckAck
  alias Proto.Packets.UserConnectcutCmd
  alias Proto.Packets.UserLoginAck
  alias Proto.Packets.UserLoginfailAck
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldStatusAck
  alias Proto.Packets.UserWorldStatusReq
  alias Proto.Packets.UserXtrapAck
  alias Proto.Packets.UserXtrapReq
  alias Proto.Packets.WorldInfo

  @type result :: {:ok, pos_integer()} | {:error, :unknown | :wrong_password | :blocked | :not_login_able | :database}

  @enforce_keys [:version_key, :auto_create?, :worlds]
  defstruct [:version_key, :auto_create?, :worlds, step: :version, pending: :none, user_no: :none]

  @type t :: %__MODULE__{
          version_key: String.t(),
          auto_create?: boolean(),
          worlds: [Settings.world()],
          step: :version | :login | :open,
          pending: :none | result(),
          user_no: :none | pos_integer()
        }

  @impl Net.Handler
  def init(settings),
    do: %__MODULE__{
      version_key: settings.client_version_key,
      auto_create?: settings.login.auto_create_accounts,
      worlds: settings.world
    }

  @impl Net.Handler
  def handle_packet(%__MODULE__{step: :version} = state, %UserClientVersionCheckReq{version_key: key}) do
    if key == state.version_key do
      {%{state | step: :login},
       [{:send, %UserClientRightversionCheckAck{xtrap_server_key_length: 1, xtrap_server_key: ""}}]}
    else
      {state, [{:send, %UserClientWrongversionCheckAck{unused: 0}}, :close]}
    end
  end

  def handle_packet(%__MODULE__{step: :version} = state, _packet), do: {state, [:close]}

  def handle_packet(%__MODULE__{step: :login} = state, %UserUsLoginReq{user_name: name, password: password}),
    do: {%{state | step: :open}, [{:perform, {:check_login, name, %Login.Secret{value: password}, state.auto_create?}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet), do: {state, [:close]}

  # The key is not looked at (L00-B5 kept).
  def handle_packet(%__MODULE__{step: :open} = state, %UserXtrapReq{}) do
    ack = {:send, %UserXtrapAck{success: 1}}
    {%{state | pending: :none}, [ack | answer(state.pending)]}
  end

  def handle_packet(%__MODULE__{step: :open, user_no: :none} = state, %UserWorldStatusReq{}), do: {state, []}

  def handle_packet(%__MODULE__{step: :open} = state, %UserWorldStatusReq{}),
    do: {state, [{:perform, {:world_list, UserWorldStatusAck, state.worlds}}]}

  def handle_packet(%__MODULE__{step: :open} = state, _packet), do: {state, []}

  defp answer(:none), do: []
  defp answer({:ok, user_no}), do: [{:perform, {:take_over, user_no}}]
  defp answer({:error, :unknown}), do: refuse(0x45)
  defp answer({:error, :wrong_password}), do: refuse(0x45)
  defp answer({:error, :blocked}), do: refuse(0x47)
  defp answer({:error, :not_login_able}), do: refuse(0x48)
  # The original answers a failed DB call like an unknown name (D01 section 3.2: nUserNo stays -1).
  defp answer({:error, :database}), do: refuse(0x45)

  defp refuse(code), do: [{:send, %UserLoginfailAck{error: code}}, :close]

  @impl Net.Handler
  def handle_info(state, {:login_checked, result}), do: {%{state | pending: result}, []}

  def handle_info(state, {:taken_over, user_no}),
    do: {%{state | user_no: user_no}, [{:perform, {:world_list, UserLoginAck, state.worlds}}]}

  def handle_info(state, {:world_list, module, infos}), do: {state, [{:send, struct!(module, worlds: infos)}]}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, :close]}

  @impl Net.Handler
  def perform({:check_login, name, %Login.Secret{value: password}, auto_create?}) do
    result =
      case Persistence.check_login(name, password) do
        {:error, :unknown} when auto_create? ->
          case Persistence.create_account(name, password) do
            {:ok, user_no} -> {:ok, user_no}
            {:error, _reason} -> {:error, :unknown}
          end

        other ->
          other
      end

    {:login_checked, result}
  end

  def perform({:take_over, user_no}) do
    :ok = Cluster.Sessions.take_over(user_no)
    {:taken_over, user_no}
  end

  def perform({:world_list, module, worlds}) do
    infos =
      for w <- worlds do
        registered? = match?({:ok, _}, Cluster.Registry.whereis_world_manager(w.number))

        %WorldInfo{
          world_no: w.number,
          name: w.name,
          status: Login.WorldStatus.status(registered?, Cluster.Registry.player_count(w.number))
        }
      end

    {:world_list, module, infos}
  end
end
