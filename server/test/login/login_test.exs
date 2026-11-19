defmodule Login.LoginTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.{
    UserClientVersionCheckReq,
    UserUsLoginReq,
    UserWorldStatusReq,
    UserWorldselectAck,
    UserWorldselectReq,
    UserXtrapReq
  }

  @key "20151116141627"
  @world_list Base.decode16!("0100494e4954494f0000000000000000000006", case: :lower)

  setup do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    :ok
  end

  defp listen(overrides \\ & &1) do
    {:ok, settings} = Settings.load(%{})
    settings = overrides.(settings)
    pid = start_supervised!({Net.Listener, {Login.Handler, 0, settings}}, id: make_ref())
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp connect(port) do
    client = TestClient.connect(~c"127.0.0.1", port)
    {:ok, <<0x07, 0x08, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

  defp send!(client, packet) do
    {:ok, client} = TestClient.send_packet(client, packet)
    client
  end

  defp recv!(client, body) do
    assert {:ok, ^body, client} = TestClient.recv_raw(client)
    client
  end

  defp closed(client), do: assert({:error, :closed} = TestClient.recv_raw(client))

  defp version(client, key \\ @key), do: send!(client, %UserClientVersionCheckReq{version_key: key})

  defp login_req(client, name, password),
    do: send!(client, %UserUsLoginReq{user_name: name, password: password, spawnapps: <<0::160>>})

  defp xtrap(client), do: send!(client, %UserXtrapReq{key_length: 0, key: ""})

  # Version check, login and xtrap; leaves the answer to the login unread.
  defp login(client, name, password) do
    client = client |> version() |> recv!(<<0x67, 0x0C, 1, 0>>) |> login_req(name, password) |> xtrap()
    recv!(client, <<0x05, 0x0C, 1>>)
  end

  defp account(name \\ "admin", password \\ "pw") do
    {:ok, _} = Persistence.create_account(name, password)
    {name, password}
  end

  @secret "5ebe2294ecd0e0f08eab7690d2a6ee69"

  defp break_database do
    repo = Persistence.Repo.active()
    repo.query!("ALTER TABLE accounts RENAME TO accounts_off")
    on_exit(fn -> repo.query!("ALTER TABLE accounts_off RENAME TO accounts") end)
  end

  for {title, auto?} <- [{"", false}, {" with auto-create", true}] do
    test "a failing database#{title}: 0x45, socket closed, no password in the log" do
      port = listen(&put_in(&1.login.auto_create_accounts, unquote(auto?)))
      break_database()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          client = port |> connect() |> login("ivy", @secret) |> recv!(<<0x09, 0x0C, 0x45, 0>>)
          closed(client)
        end)

      assert log =~ "the database failed in check_login"
      refute log =~ @secret
      refute log =~ "GenServer"
      refute log =~ "terminating"
    end
  end

  test "the password is not printed with the effect" do
    {:ok, settings} = Settings.load(%{})
    state = %{Login.Handler.init(settings) | step: :login}
    packet = %UserUsLoginReq{user_name: "ivy", password: @secret, spawnapps: <<0::160>>}
    {_state, effects} = Login.Handler.handle_packet(state, packet)
    refute inspect(effects) =~ @secret
    assert [{:perform, {:check_login, "ivy", %Login.Secret{value: @secret}, _}}] = effects
  end

  test "wrong version key" do
    client = listen() |> connect() |> version("20140101000000")
    client = recv!(client, <<0x66, 0x0C, 0>>)
    closed(client)
  end

  test "right version key" do
    listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>)
  end

  test "first packet not the version check" do
    client = listen() |> connect() |> send!(%UserWorldStatusReq{})
    closed(client)
  end

  test "second packet not the login" do
    client = listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>) |> xtrap()
    closed(client)
  end

  test "login of the wrong length: dropped, the next login is handled" do
    {name, password} = account()
    client = listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>)
    {:ok, client} = TestClient.send_raw(client, <<0x5A, 0x0C>> <> :binary.copy(<<0>>, 315))
    assert {:error, :timeout} = TestClient.recv_raw(client, 100)

    client = client |> login_req(name, password) |> xtrap() |> recv!(<<0x05, 0x0C, 1>>)
    assert {:ok, <<0x0A, 0x0C, _::binary>>, _client} = TestClient.recv_raw(client)
  end

  test "wrong password" do
    {name, _} = account()
    client = listen() |> connect() |> login(name, "other")
    client = recv!(client, <<0x09, 0x0C, 0x45, 0>>)
    closed(client)
  end

  test "blocked" do
    {name, password} = account()
    :ok = Persistence.set_blocked(name, true)
    client = listen() |> connect() |> login(name, password) |> recv!(<<0x09, 0x0C, 0x47, 0>>)
    closed(client)
  end

  test "not login-able" do
    {name, password} = account()
    :ok = Persistence.set_login_able(name, false)
    client = listen() |> connect() |> login(name, password) |> recv!(<<0x09, 0x0C, 0x48, 0>>)
    closed(client)
  end

  test "auto-create off" do
    port = listen(&put_in(&1.login.auto_create_accounts, false))
    client = port |> connect() |> login("nobody", "pw") |> recv!(<<0x09, 0x0C, 0x45, 0>>)
    closed(client)
    assert Persistence.check_login("nobody", "pw") == {:error, :unknown}
  end

  test "auto-create on" do
    port = listen(&put_in(&1.login.auto_create_accounts, true))
    port |> connect() |> login("newbie", "pw") |> recv!(<<0x0A, 0x0C>> <> @world_list)
    port |> connect() |> login("newbie", "pw") |> recv!(<<0x0A, 0x0C>> <> @world_list)
    client = port |> connect() |> login("newbie", "other") |> recv!(<<0x09, 0x0C, 0x45, 0>>)
    closed(client)
  end

  test "auto-create with an invalid name" do
    port = listen(&put_in(&1.login.auto_create_accounts, true))
    client = port |> connect() |> login("a b", "pw") |> recv!(<<0x09, 0x0C, 0x45, 0>>)
    closed(client)
  end

  test "success and world status" do
    {name, password} = account()

    client =
      listen()
      |> connect()
      |> login(name, password)
      |> recv!(<<0x0A, 0x0C>> <> @world_list)
      |> send!(%UserWorldStatusReq{})

    recv!(client, <<0x1C, 0x0C>> <> @world_list)
  end

  test "after the login: a second xtrap is answered, other packets are ignored" do
    {name, password} = account()

    client =
      listen()
      |> connect()
      |> login(name, password)
      |> recv!(<<0x0A, 0x0C>> <> @world_list)
      |> xtrap()
      |> recv!(<<0x05, 0x0C, 1>>)
      |> version()
      |> send!(%UserWorldStatusReq{})

    recv!(client, <<0x1C, 0x0C>> <> @world_list)
  end

  test "world status before the login answer is ignored" do
    {name, password} = account()
    client = listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>) |> login_req(name, password)
    client = client |> send!(%UserWorldStatusReq{}) |> xtrap() |> recv!(<<0x05, 0x0C, 1>>)
    client = recv!(client, <<0x0A, 0x0C>> <> @world_list)
    {:ok, client} = TestClient.send_raw(client, <<0x04, 0x08>>)
    recv!(client, <<0x05, 0x08>>)
  end

  test "any xtrap key is accepted" do
    {name, password} = account()
    client = listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>) |> login_req(name, password)
    {:ok, client} = TestClient.send_raw(client, <<0x04, 0x0C, 29>> <> :binary.copy(<<0xFF>>, 29))
    recv!(client, <<0x05, 0x0C, 1>>)
  end

  test "a world without a registered WorldManager has status 0" do
    {name, password} = account()
    port = listen(&put_in(&1.world, [%{number: 0, name: "INITIO"}, %{number: 77, name: "CLOSED"}]))

    expected =
      <<0x0A, 0x0C, 2, 0>> <>
        "INITIO" <> :binary.copy(<<0>>, 10) <> <<6, 77>> <> "CLOSED" <> :binary.copy(<<0>>, 10) <> <<0>>

    port |> connect() |> login(name, password) |> recv!(expected)
  end

  test "a second login of the same account cuts the first" do
    {name, password} = account()
    port = listen()
    first = port |> connect() |> login(name, password) |> recv!(<<0x0A, 0x0C>> <> @world_list)
    second = port |> connect() |> login(name, password) |> recv!(<<0x0A, 0x0C>> <> @world_list)
    first = recv!(first, <<0x17, 0x0C, 0x83, 0x06>>)
    closed(first)
    second |> send!(%UserWorldStatusReq{}) |> recv!(<<0x1C, 0x0C>> <> @world_list)
  end

  test "selecting a world without a WorldManager answers status 0 and keeps the session" do
    {name, password} = account()
    client = listen() |> connect() |> login(name, password) |> recv!(<<0x0A, 0x0C>> <> @world_list)

    expected =
      <<0x0C, 0x0C, 0>> <> "127.0.0.1" <> :binary.copy(<<0>>, 7) <> <<0x96, 0x23>> <> :binary.copy(<<0>>, 64)

    client = client |> send!(%UserWorldselectReq{world_no: 77}) |> recv!(expected)
    client |> send!(%UserWorldStatusReq{}) |> recv!(<<0x1C, 0x0C>> <> @world_list)
  end

  test "a world select before the login answer is ignored" do
    {name, password} = account()
    client = listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>) |> login_req(name, password)
    client = client |> send!(%UserWorldselectReq{world_no: 0}) |> xtrap() |> recv!(<<0x05, 0x0C, 1>>)
    recv!(client, <<0x0A, 0x0C>> <> @world_list)
  end

  test "a successful world select ends the session at Login" do
    {name, password} = account()
    client = listen() |> connect() |> login(name, password) |> recv!(<<0x0A, 0x0C>> <> @world_list)
    client = send!(client, %UserWorldselectReq{world_no: 0})

    assert {:ok, %UserWorldselectAck{world_status: 6, ip: "127.0.0.1", port: 9110, validate: key}, client} =
             TestClient.recv(client)

    assert length(key) == 32 and Enum.any?(key, &(&1 != 0))
    client = send!(client, %UserWorldStatusReq{})
    {:ok, client} = TestClient.send_raw(client, <<0x04, 0x08>>)
    recv!(client, <<0x05, 0x08>>)
  end
end
