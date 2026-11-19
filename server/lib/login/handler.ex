defmodule Login.Handler do
  @moduledoc """
  Packet handler of the Login part: version check, account login, the world list and the world select
  (flows: `docs/technical/flows/login.md`, `docs/technical/flows/world-select.md`).

  `handle_packet/2` and `handle_info/2` are pure. Database and `Cluster` work is a `{:perform, request}` effect
  that `perform/1` carries out; its result comes back through `handle_info/2`.

  A client coming back from WorldManager logs in with a login token (`0x0C37`; flow:
  `docs/technical/flows/return-to-world-list.md`). `0x0C18` is ignored.
  """

  @behaviour Net.Handler

  alias Proto.Packets.UserClientRightversionCheckAck
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserClientWrongversionCheckAck
  alias Proto.Packets.UserConnectcutCmd
  alias Proto.Packets.UserLoginAck
  alias Proto.Packets.UserLoginfailAck
  alias Proto.Packets.UserLoginWithOtpReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldStatusAck
  alias Proto.Packets.UserWorldStatusReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapAck
  alias Proto.Packets.UserXtrapReq
  alias Proto.Packets.WorldInfo

  @type result :: {:ok, pos_integer()} | {:error, :unknown | :wrong_password | :blocked | :not_login_able | :database}

  @enforce_keys [:version_key, :auto_create?, :worlds, :wm_address]
  defstruct [
    :version_key,
    :auto_create?,
    :worlds,
    :wm_address,
    step: :version,
    pending: :none,
    user_no: :none,
    user_name: :none
  ]

  @type t :: %__MODULE__{
          version_key: String.t(),
          auto_create?: boolean(),
          worlds: [Settings.world()],
          wm_address: {String.t(), pos_integer()},
          step: :version | :login | :open,
          pending: :none | result(),
          user_no: :none | pos_integer(),
          user_name: :none | String.t()
        }

  @impl Net.Handler
  def init(settings),
    do: %__MODULE__{
      version_key: settings.client_version_key,
      auto_create?: settings.login.auto_create_accounts,
      worlds: settings.world,
      wm_address: {settings.public_host, settings.world_manager.port}
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
    do:
      {%{state | step: :open, user_name: name},
       [{:perform, {:check_login, name, %Login.Secret{value: password}, state.auto_create?}}]}

  def handle_packet(%__MODULE__{step: :login} = state, %UserLoginWithOtpReq{otp: otp}),
    do: {%{state | step: :open}, [{:perform, {:take_token, otp}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet), do: {state, [:close]}

  # The key is not looked at (L00-B5 kept).
  def handle_packet(%__MODULE__{step: :open} = state, %UserXtrapReq{}) do
    ack = {:send, %UserXtrapAck{success: 1}}
    {%{state | pending: :none}, [ack | answer(state.pending)]}
  end

  def handle_packet(%__MODULE__{step: :open, user_no: :none} = state, %UserWorldStatusReq{}), do: {state, []}

  def handle_packet(%__MODULE__{step: :open} = state, %UserWorldStatusReq{}),
    do: {state, [{:perform, {:world_list, UserWorldStatusAck, state.worlds}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %UserWorldselectReq{world_no: world_no})
      when is_integer(user_no),
      do: {state, [{:perform, {:select_world, world_no, user_no, state.user_name, state.wm_address}}]}

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

  def handle_info(state, {:token_taken, {:ok, user_no, user_name}}),
    do: {%{state | user_no: user_no, user_name: user_name}, [{:perform, {:world_list, UserLoginAck, state.worlds}}]}

  # No client text for 0x52 (L00-B4 kept by decision).
  def handle_info(state, {:token_taken, :error}), do: {state, refuse(0x52)}

  def handle_info(state, {:world_list, module, infos}), do: {state, [{:send, struct!(module, worlds: infos)}]}

  def handle_info(state, {:world_selected, true, ack}), do: {%{state | user_no: :none}, [{:send, ack}]}
  def handle_info(state, {:world_selected, false, ack}), do: {state, [{:send, ack}]}

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

  def perform({:take_token, otp}) do
    case Login.Tokens.take(otp) do
      {:ok, {user_no, user_name}} ->
        :ok = Cluster.Sessions.take_over(user_no)
        {:token_taken, {:ok, user_no, user_name}}

      :error ->
        {:token_taken, :error}
    end
  end

  def perform({:world_list, module, worlds}) do
    infos =
      for w <- worlds do
        %WorldInfo{world_no: w.number, name: w.name, status: status(w.number)}
      end

    {:world_list, module, infos}
  end

  def perform({:select_world, world_no, user_no, user_name, {host, port}}) do
    status = status(world_no)
    validate = if status == 0, do: List.duplicate(0, 32), else: for(<<word::little-16 <- Random.bytes(64)>>, do: word)

    # Status 5 gets a key without a reservation (L00-B3 fixed, the client bytes stay as captured).
    handed_off? = status in 6..10

    if handed_off? do
      :ok = Cluster.WorldManager.expect_login(world_no, %{user_no: user_no, user_name: user_name, validate: validate})
      :ok = Cluster.Sessions.leave(user_no)
    end

    {:world_selected, handed_off?, %UserWorldselectAck{world_status: status, ip: host, port: port, validate: validate}}
  end

  defp status(world_no) do
    registered? = match?({:ok, _}, Cluster.Registry.whereis_world_manager(world_no))
    Login.WorldStatus.status(registered?, Cluster.Registry.player_count(world_no))
  end
end
