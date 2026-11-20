defmodule Pinata.StartTest do
  # Stops and restarts the application and sets environment variables, so it cannot run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @supervisors [Persistence.Supervisor, Cluster.Root, Login.Supervisor, WorldManager.Supervisor, Zone.Supervisor]

  setup do
    :ok = Application.stop(:pinata)
    config = System.fetch_env!("PINATA_CONFIG")

    on_exit(fn ->
      System.put_env("PINATA_CONFIG", config)
      System.delete_env("PINATA_PARTS")
      _ = Application.stop(:pinata)
      :ok = Application.start(:pinata)
    end)
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    assert {:ok, <<4, 0x07, 0x08, seed::little-16>>} = :gen_tcp.recv(socket, 5, 1000)
    {socket, Proto.Cipher.new(seed)}
  end

  defp encrypted(cipher, body) do
    {enc, cipher} = Proto.Cipher.crypt(cipher, body)
    {:ok, frame} = Proto.Framing.frame(enc)
    {frame, cipher}
  end

  # The ports of the stopped application of the test VM (TestPorts), so no listener uses a fixed port.
  defp ports(login \\ TestPorts.app().login) do
    %{wm: wm, zone: zone} = TestPorts.app()
    "[login]\nport = #{login}\n\n[world_manager]\nport = #{wm}\n\n[zone]\nport = #{zone}\n"
  end

  defp running, do: Enum.filter(@supervisors, &Process.whereis/1)

  defp use_file(tmp_dir, toml) do
    path = Path.join(tmp_dir, "pinata.toml")
    File.write!(path, "data_dir = #{inspect(System.fetch_env!("PINATA_TEST_DATA_DIR"))}\n" <> toml)
    System.put_env("PINATA_CONFIG", path)
  end

  # The job environment chooses the database (CI runs the suite against Postgres too), so the expected name follows it.
  defp database,
    do: if(String.starts_with?(System.fetch_env!("DATABASE_URL"), "sqlite:"), do: "sqlite", else: "postgres")

  test "with only data_dir and the ports set every supervisor starts", %{tmp_dir: tmp_dir} do
    %{login: login, wm: wm, zone: zone} = TestPorts.app()
    use_file(tmp_dir, ports())
    log = TestLog.capture(fn -> assert :ok = Application.start(:pinata) end)
    assert running() == @supervisors
    assert Process.whereis(Cluster.DataDigest) == nil
    assert Process.whereis(Cluster.NodeLog) == nil
    assert Process.whereis(Login.WorldWatch) == nil

    assert log =~ "[info] Login: listening on 0.0.0.0:#{login}\n"
    assert log =~ "[info] WorldManager: listening on 0.0.0.0:#{wm}\n"
    assert log =~ "[info] Zone: listening on 0.0.0.0:#{zone}\n"

    assert log =~
             "[info] Pinata: node started, parts login, world_manager, zone, single-node mode, database #{database()}\n"

    refute log =~ System.fetch_env!("DATABASE_URL")
    refute log =~ "test.db"
    refute log =~ "pinata.db"

    for port <- [login, wm, zone] do
      {socket, cipher} = connect(port)

      # 0x0807 reaches the Zone stub handler, which ignores it; the socket stays open. Login and WorldManager close on it: they expect 0x0C65 and 0x0C0F.
      {seed_packet, cipher} = if port in [login, wm], do: {<<>>, cipher}, else: encrypted(cipher, <<0x07, 0x08, 0, 0>>)
      :ok = :gen_tcp.send(socket, seed_packet)
      {heartbeat, _cipher} = encrypted(cipher, <<0x04, 0x08>>)
      :ok = :gen_tcp.send(socket, heartbeat)
      assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
    end
  end

  test "with a valid file every supervisor starts", %{tmp_dir: tmp_dir} do
    use_file(tmp_dir, "public_host = \"203.0.113.7\"\n\n" <> ports())
    assert :ok = Application.start(:pinata)
    assert running() == @supervisors
  end

  test "a file with two errors reports both and the node does not start", %{tmp_dir: tmp_dir} do
    use_file(tmp_dir, "bogus = 1\n\n[login]\nport = 0\n")

    output = capture_io(:stderr, fn -> assert {:error, _reason} = Application.start(:pinata) end)

    assert output =~ "bogus: unknown key"
    assert output =~ "login.port: "
    assert running() == []
  end

  test "a missing data directory stops the start and names the import task", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "nope")
    path = Path.join(tmp_dir, "pinata.toml")
    File.write!(path, "data_dir = #{inspect(missing)}\n")
    System.put_env("PINATA_CONFIG", path)

    output = capture_io(:stderr, fn -> assert {:error, _reason} = Application.start(:pinata) end)

    assert output =~ "mix pinata.import_data"
    assert output =~ missing
    assert running() == []
  end

  test "a port in use is one line on standard error and the node does not start", %{tmp_dir: tmp_dir} do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)
    use_file(tmp_dir, ports(port))

    output = capture_io(:stderr, fn -> assert {:error, _reason} = Application.start(:pinata) end)
    :ok = :gen_tcp.close(listener)

    assert output =~ "Login: cannot listen on port #{port}: address already in use. The node does not start."
    assert running() == []
  end

  test "PINATA_PARTS=login starts only the Login part", %{tmp_dir: tmp_dir} do
    use_file(tmp_dir, ports())
    System.put_env("PINATA_PARTS", "login")
    log = TestLog.capture(fn -> assert :ok = Application.start(:pinata) end)
    assert running() == [Persistence.Supervisor, Cluster.Root, Login.Supervisor]
    assert is_pid(Process.whereis(Cluster.DataDigest))
    assert is_pid(Process.whereis(Cluster.NodeLog))
    assert is_pid(Process.whereis(Login.WorldWatch))
    assert log =~ "[info] Pinata: node started, parts login, multi-node mode, database #{database()}\n"
    connect(TestPorts.app().login)
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", TestPorts.app().wm, [:binary, active: false])
  end
end
