# Smoke test of the Docker Compose example (docs/user/multi-node.md): login -> world select -> character list.
# Run with `MIX_ENV=test mix run --no-start test/support/compose_smoke.exs` after `docker compose up -d` and
# `Persistence.Release.create_account("smoke")` with the password "smoke-password".
Code.require_file("test_client.ex", __DIR__)

alias Proto.Packets.{
  UserClientVersionCheckReq,
  UserLoginworldReq,
  UserUsLoginReq,
  UserWorldselectAck,
  UserWorldselectReq,
  UserXtrapReq
}

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
  client = connect.(9010)
  client = send!.(client, %UserClientVersionCheckReq{version_key: "20151116141627"})
  {:ok, <<0x67, 0x0C, 1, 0>>, client} = TestClient.recv_raw(client)
  password = Base.encode16(:crypto.hash(:md5, "smoke-password"), case: :lower)
  client = send!.(client, %UserUsLoginReq{user_name: "smoke", password: password, spawnapps: <<0::160>>})
  client = send!.(client, %UserXtrapReq{key_length: 0, key: ""})
  {:ok, <<0x05, 0x0C, 1>>, client} = TestClient.recv_raw(client)
  {:ok, <<0x0A, 0x0C, _::binary>>, client} = TestClient.recv_raw(client)
  client = send!.(client, %UserWorldselectReq{world_no: 0})
  {:ok, %UserWorldselectAck{world_status: 6, port: 9110, validate: key}, _client} = TestClient.recv(client)

  wm = connect.(9110)
  wm = send!.(wm, %UserLoginworldReq{user_name: "smoke", validate: key})
  {:ok, <<0x14, 0x0C, _::binary>>, _wm} = TestClient.recv_raw(wm)
  :ok
end

# the nodes need a moment to connect and to sync :global
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
    IO.puts("compose smoke test passed")

  error ->
    IO.puts(:stderr, "compose smoke test failed: " <> Exception.format(:error, error))
    System.halt(1)
end
