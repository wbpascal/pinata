defmodule SettingsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp load(tmp_dir, toml, env \\ %{}) do
    path = Path.join(tmp_dir, "pinata.toml")
    File.write!(path, toml)
    Settings.load(Map.merge(%{"PINATA_CONFIG" => path}, env))
  end

  test "defaults" do
    assert {:ok, settings} = Settings.load(%{})

    assert settings == %{
             parts: [:login, :world_manager, :zone],
             data_dir: "./data",
             public_host: "127.0.0.1",
             client_version_key: "20151116141627",
             login: %{port: 9010, auto_create_accounts: true},
             world_manager: %{port: 9110},
             zone: %{port: 9210},
             world: [%{number: 0, name: "INITIO"}],
             database: %{url: "sqlite:./data/pinata.db"},
             cluster: %{nodes: []},
             connection: %{max_packets_per_second: 100, max_unsent_bytes: 1_048_576},
             data: %{strict_references: true}
           }
  end

  test "a valid file", %{tmp_dir: dir} do
    toml = """
    public_host = "10.0.0.1"
    [login]
    port = 9011
    [cluster]
    nodes = ["a@b"]
    [[world]]
    number = 1
    name = "A"
    [[world]]
    number = 2
    """

    assert {:ok, s} = load(dir, toml)
    assert s.public_host == "10.0.0.1"
    assert s.login.port == 9011
    assert s.cluster.nodes == ["a@b"]
    assert s.world == [%{number: 1, name: "A"}, %{number: 2, name: "INITIO"}]
  end

  test "DATABASE_URL overrides the file", %{tmp_dir: dir} do
    toml = "[database]\nurl = \"file:x\"\n"
    assert {:ok, %{database: %{url: "file:x"}}} = load(dir, toml)
    assert {:ok, %{database: %{url: "env:y"}}} = load(dir, toml, %{"DATABASE_URL" => "env:y"})
  end

  test "auto_create_accounts default and override", %{tmp_dir: dir} do
    assert {:ok, %{login: %{auto_create_accounts: false}}} = load(dir, "", %{"PINATA_PARTS" => "login"})
    assert {:ok, %{login: %{auto_create_accounts: false}}} = load(dir, "[cluster]\nnodes = [\"a@b\"]\n")
    on = "[login]\nauto_create_accounts = true\n"
    assert {:ok, %{login: %{auto_create_accounts: true}}} = load(dir, on, %{"PINATA_PARTS" => "login"})
    assert {:ok, %{login: %{auto_create_accounts: true}}} = load(dir, on <> "[cluster]\nnodes = [\"a@b\"]\n")
  end

  test "PINATA_PARTS order" do
    assert {:ok, %{parts: [:login, :zone]}} = Settings.load(%{"PINATA_PARTS" => "zone,login"})
  end

  test "two errors in one file", %{tmp_dir: dir} do
    assert {:error, problems} = load(dir, "bogus = 1\n[login]\nport = 0\n")
    assert length(problems) == 2
    assert Enum.any?(problems, &(&1 =~ "bogus: unknown key"))
    assert Enum.any?(problems, &(String.starts_with?(&1, "login.port:") and &1 =~ "got: 0"))
  end

  test "single problems", %{tmp_dir: dir} do
    assert {:error, [p]} = load(dir, "[login]\nfoo = 1\n")
    assert p =~ "login.foo: unknown key"
    assert {:error, [p]} = load(dir, "[[world]]\nnme = \"x\"\n")
    assert p =~ "world[0].nme: unknown key"
    assert {:error, [p]} = load(dir, "world = [{number = 1}, 5]\n")
    assert p =~ "world[1]: expected a table"
    assert {:error, [p]} = load(dir, "login = 5\n")
    assert p =~ "login: expected a table"
    assert {:error, [p]} = load(dir, "this is not toml")
    assert p =~ "not valid TOML"
    assert {:error, [p]} = Settings.load(%{"PINATA_CONFIG" => Path.join(dir, "missing.toml")})
    assert p =~ "cannot read the settings file"
    assert {:error, [p]} = Settings.load(%{"PINATA_PARTS" => "login,zon"})
    assert p =~ "unknown part"
  end

  test "the schema is valid NimbleOptions" do
    NimbleOptions.new!(Settings.Schema.schema())
  end
end
