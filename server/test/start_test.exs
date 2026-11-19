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

  defp running, do: Enum.filter(@supervisors, &Process.whereis/1)

  defp use_file(tmp_dir, toml) do
    path = Path.join(tmp_dir, "pinata.toml")
    File.write!(path, "data_dir = #{inspect(System.fetch_env!("PINATA_TEST_DATA_DIR"))}\n" <> toml)
    System.put_env("PINATA_CONFIG", path)
  end

  test "with only data_dir set every supervisor starts", %{tmp_dir: tmp_dir} do
    use_file(tmp_dir, "")
    assert :ok = Application.start(:pinata)
    assert running() == @supervisors
    assert Process.whereis(Cluster.DataDigest) == nil

    for port <- [9010, 9110, 9210] do
      {socket, cipher} = connect(port)

      # 0x0807 reaches the Zone stub handler, which ignores it; the socket stays open. Login and WorldManager close on it: they expect 0x0C65 and 0x0C0F.
      {seed_packet, cipher} = if port in [9010, 9110], do: {<<>>, cipher}, else: encrypted(cipher, <<0x07, 0x08, 0, 0>>)
      :ok = :gen_tcp.send(socket, seed_packet)
      {heartbeat, _cipher} = encrypted(cipher, <<0x04, 0x08>>)
      :ok = :gen_tcp.send(socket, heartbeat)
      assert {:ok, <<2, 5, 8>>} = :gen_tcp.recv(socket, 3, 1000)
    end
  end

  test "with a valid file every supervisor starts", %{tmp_dir: tmp_dir} do
    use_file(tmp_dir, "public_host = \"203.0.113.7\"\n\n[login]\nport = 9011\n")
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

  test "PINATA_PARTS=login starts only the Login part", %{tmp_dir: _tmp_dir} do
    System.put_env("PINATA_PARTS", "login")
    assert :ok = Application.start(:pinata)
    assert running() == [Persistence.Supervisor, Cluster.Root, Login.Supervisor]
    assert is_pid(Process.whereis(Cluster.DataDigest))
    connect(9010)
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", 9110, [:binary, active: false])
  end
end
