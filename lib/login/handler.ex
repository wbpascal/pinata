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
      {state, [{:send, %UserClientWrongversionCheckAck{unused: 0}}, {:close, :info, "wrong version key"}]}
    end
  end

  def handle_packet(%__MODULE__{step: :version} = state, _packet), do: {state, [{:close, :info, "wrong first packet"}]}

  def handle_packet(%__MODULE__{step: :login} = state, %UserUsLoginReq{user_name: name, password: password}),
    do:
      {%{state | step: :open, user_name: name},
       [{:perform, {:check_login, name, %Login.Secret{value: password}, state.auto_create?}}]}

  def handle_packet(%__MODULE__{step: :login} = state, %UserLoginWithOtpReq{otp: otp}),
    do: {%{state | step: :open}, [{:perform, {:take_token, otp}}]}

  def handle_packet(%__MODULE__{step: :login} = state, _packet),
    do: {state, [{:close, :info, "unexpected packet instead of the login"}]}

  # The key is not looked at (L00-B5 kept).
  def handle_packet(%__MODULE__{step: :open} = state, %UserXtrapReq{}) do
    ack = {:send, %UserXtrapAck{success: 1}}
    {%{state | pending: :none}, [ack | answer(state.pending, state.user_name)]}
  end

  def handle_packet(%__MODULE__{step: :open, user_no: :none} = state, %UserWorldStatusReq{}), do: {state, []}

  def handle_packet(%__MODULE__{step: :open} = state, %UserWorldStatusReq{}),
    do: {state, [{:perform, {:world_list, UserWorldStatusAck, state.worlds}}]}

  def handle_packet(%__MODULE__{step: :open, user_no: user_no} = state, %UserWorldselectReq{world_no: world_no})
      when is_integer(user_no),
      do: {state, [{:perform, {:select_world, world_no, user_no, state.user_name, state.wm_address}}]}

  def handle_packet(%__MODULE__{step: :open} = state, _packet), do: {state, []}

  defp answer(:none, _name), do: []
  defp answer({:ok, user_no}, _name), do: [{:perform, {:take_over, user_no}}]
  defp answer({:error, :unknown}, name), do: refuse(0x45, account(name) <> ", unknown account")
  defp answer({:error, :wrong_password}, name), do: refuse(0x45, account(name) <> ", wrong password")
  defp answer({:error, :blocked}, name), do: refuse(0x47, account(name) <> ", blocked")
  defp answer({:error, :not_login_able}, name), do: refuse(0x48, account(name) <> ", not login-able")
  # The original answers a failed DB call like an unknown name (D01 section 3.2: nUserNo stays -1).
  defp answer({:error, :database}, name), do: refuse(0x45, account(name) <> ", database failure")

  defp refuse(code, reason),
    do: [{:send, %UserLoginfailAck{error: code}}, {:close, :info, "login refused, " <> reason}]

  # 0x45: the code of a database failure (D01 section 3.2).
  defp replace_timeout(name),
    do: [
      {:send, %UserLoginfailAck{error: 0x45}},
      {:close, :error, "login refused, " <> account(name) <> ", the old session did not end in time"}
    ]

  # inspect/1: a typed name can never break the one-line rule.
  defp account(name), do: "account " <> inspect(name)

  @impl Net.Handler
  def handle_info(state, {:login_checked, result}), do: {%{state | pending: result}, []}

  def handle_info(state, {:taken_over, user_no, :ok}),
    do:
      {%{state | user_no: user_no},
       [
         {:log, :info, "login accepted, " <> account(state.user_name)},
         {:perform, {:world_list, UserLoginAck, state.worlds}}
       ]}

  def handle_info(state, {:taken_over, _user_no, {:error, :timeout}}), do: {state, replace_timeout(state.user_name)}

  def handle_info(state, {:token_taken, {:ok, user_no, user_name}}),
    do:
      {%{state | user_no: user_no, user_name: user_name},
       [
         {:log, :info, "login accepted with a login token, " <> account(user_name)},
         {:perform, {:world_list, UserLoginAck, state.worlds}}
       ]}

  def handle_info(state, {:token_taken, {:error, :timeout, user_name}}), do: {state, replace_timeout(user_name)}

  # No client text for 0x52 (L00-B4 kept by decision).
  def handle_info(state, {:token_taken, :error}), do: {state, refuse(0x52, "unknown or expired login token")}

  def handle_info(state, {:world_list, module, infos}), do: {state, [{:send, struct!(module, worlds: infos)}]}

  def handle_info(state, {:world_selected, true, ack}), do: {%{state | user_no: :none}, [{:send, ack}]}
  def handle_info(state, {:world_selected, false, ack}), do: {state, [{:send, ack}]}

  def handle_info(state, {:cluster, :session_replaced}),
    do: {state, [{:send, %UserConnectcutCmd{error: 0x683}}, {:close, :info, "session replaced"}]}

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

  def perform({:take_over, user_no}), do: {:taken_over, user_no, Cluster.Sessions.take_over(user_no)}

  def perform({:take_token, otp}) do
    case Login.Tokens.take(otp) do
      {:ok, {user_no, user_name}} ->
        case Cluster.Sessions.take_over(user_no) do
          :ok -> {:token_taken, {:ok, user_no, user_name}}
          {:error, :timeout} -> {:token_taken, {:error, :timeout, user_name}}
        end

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
