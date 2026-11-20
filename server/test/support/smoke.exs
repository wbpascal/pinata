# Smoke test of a running server (docs/technical/testing.md, "Smoke test"): login -> world select -> character list,
# against 127.0.0.1. The Login port is the argument; the WorldManager port comes from the world-select answer.
# Run with `MIX_ENV=test mix run --no-start test/support/smoke.exs <Login port>` after the account "smoke" was created
# with the password "smoke-password". CI runs it against the Docker Compose example and the Windows release.
Code.require_file("test_client.ex", __DIR__)

alias Proto.Packets.{
  UserClientVersionCheckReq,
  UserLoginworldReq,
  UserUsLoginReq,
  UserWorldselectAck,
  UserWorldselectReq,
  UserXtrapReq
}

login_port =
  case System.argv() do
    [port] ->
      String.to_integer(port)

    _other ->
      IO.puts(:stderr, "usage: mix run --no-start test/support/smoke.exs <Login port>")
      System.halt(2)
  end

connect = fn port ->
  client = TestClient.connect(~c"127.0.0.1", port)
  {:ok, <<0x07, 0x08, _::binary>>, client} = TestClient.recv_raw(client)
  client
end

send! = fn client, packet ->
  {:ok, client} = TestClient.send_packet(client, packet)
  client
end

pass = fn ->
  client = connect.(login_port)
  client = send!.(client, %UserClientVersionCheckReq{version_key: "20151116141627"})
  {:ok, <<0x67, 0x0C, 1, 0>>, client} = TestClient.recv_raw(client)
  password = Base.encode16(:crypto.hash(:md5, "smoke-password"), case: :lower)
  client = send!.(client, %UserUsLoginReq{user_name: "smoke", password: password, spawnapps: <<0::160>>})
  client = send!.(client, %UserXtrapReq{key_length: 0, key: ""})
  {:ok, <<0x05, 0x0C, 1>>, client} = TestClient.recv_raw(client)
  {:ok, <<0x0A, 0x0C, _::binary>>, client} = TestClient.recv_raw(client)
  client = send!.(client, %UserWorldselectReq{world_no: 0})
  {:ok, %UserWorldselectAck{world_status: 6, port: wm_port, validate: key}, _client} = TestClient.recv(client)

  wm = connect.(wm_port)
  wm = send!.(wm, %UserLoginworldReq{user_name: "smoke", validate: key})
  {:ok, <<0x14, 0x0C, _::binary>>, _wm} = TestClient.recv_raw(wm)
  :ok
end

# the nodes need a moment to start, to connect and to sync :global
result =
  Enum.reduce_while(1..15, nil, fn attempt, _ ->
    try do
      :ok = pass.()
      {:halt, :ok}
    rescue
      error ->
        if attempt < 15, do: Process.sleep(2000)
        {:cont, error}
    end
  end)

case result do
  :ok ->
    IO.puts("smoke test passed")

  error ->
    IO.puts(:stderr, "smoke test failed: " <> Exception.format(:error, error))
    System.halt(1)
end
