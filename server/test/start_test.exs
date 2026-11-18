defmodule Pinata.StartTest do
  # Stops and restarts the application and sets environment variables, so it cannot run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @supervisors [Persistence.Supervisor, Cluster.Root, Login.Supervisor, WorldManager.Supervisor, Zone.Supervisor]

  setup do
    :ok = Application.stop(:pinata)

    on_exit(fn ->
      System.delete_env("FIESTA_CONFIG")
      System.delete_env("FIESTA_PARTS")
      _ = Application.stop(:pinata)
      :ok = Application.start(:pinata)
    end)
  end

  defp running, do: Enum.filter(@supervisors, &Process.whereis/1)

  defp use_file(tmp_dir, toml) do
    path = Path.join(tmp_dir, "fiesta.toml")
    File.write!(path, toml)
    System.put_env("FIESTA_CONFIG", path)
  end

  test "with no file every supervisor starts" do
    assert :ok = Application.start(:pinata)
    assert running() == @supervisors
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

  test "FIESTA_PARTS=login starts only the Login part", %{tmp_dir: _tmp_dir} do
    System.put_env("FIESTA_PARTS", "login")
    assert :ok = Application.start(:pinata)
    assert running() == [Persistence.Supervisor, Cluster.Root, Login.Supervisor]
  end
end
