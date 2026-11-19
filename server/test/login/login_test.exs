defmodule Login.LoginTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.{
    UserClientVersionCheckReq,
    UserUsLoginReq,
    UserWorldStatusReq,
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

  test "login of the wrong length: no answer, socket closed" do
    client = listen() |> connect() |> version() |> recv!(<<0x67, 0x0C, 1, 0>>)
    {:ok, client} = TestClient.send_raw(client, <<0x5A, 0x0C>> <> :binary.copy(<<0>>, 315))
    closed(client)
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
end
