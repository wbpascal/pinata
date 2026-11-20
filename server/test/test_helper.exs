# The custom Credo checks live outside lib/ (Credo is not a production dependency).
"../credo/checks/*.ex" |> Path.expand(__DIR__) |> Path.wildcard() |> Enum.each(&Code.require_file/1)

# Under `mix check` the credo step leaves Credo.Supervisor running although `mix test` stopped the app;
# starting it again would print "already started" notices.
if Process.whereis(Credo.Supervisor) == nil, do: {:ok, _} = Application.ensure_all_started(:credo)

# `mix test` runs with --no-start (alias in mix.exs): the database is chosen here, then the application starts.
_ = Application.stop(:pinata)
{:ok, _apps} = Application.ensure_all_started(:logger)
Application.put_env(:pinata, :password_iterations, 1_000)
# The peers of the multi-node tests share the SQLite file of the test VM (docs/technical/testing.md).
Application.put_env(:pinata, :sqlite_in_multi_node, true)

if System.get_env("DATABASE_URL") in [nil, ""] do
  path = Path.expand("../tmp/test.db", __DIR__)
  Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
  System.put_env("DATABASE_URL", "sqlite:" <> path)
end

Logger.configure(level: :warning)

source = Path.expand("../../Files/Server/2016/9Data", __DIR__)

# Git LFS pointers are a few hundred bytes; the real ItemInfo.shn is several MB.
if not File.exists?(Path.join(source, "Shine/ItemInfo.shn")) or
     File.stat!(Path.join(source, "Shine/ItemInfo.shn")).size < 1_000_000 do
  raise "the tests need Files/Server/2016/9Data (run: git lfs pull)"
end

# Test client and replay harness, TestPorts (docs/technical/testing.md).
{:ok, _modules, _diagnostics} =
  "support/**/*.ex"
  |> Path.expand(__DIR__)
  |> Path.wildcard()
  |> Kernel.ParallelCompiler.require(return_diagnostics: true)

# Path.expand/1 turns the backslashes of a Windows temp path into slashes: the tests build wildcard patterns from it.
dir = Path.join(Path.expand(System.tmp_dir!()), "pinata-test-data-#{System.pid()}")
File.rm_rf!(dir)
{:ok, _report} = GameData.Import.run(source, dir)
ports = TestPorts.choose_app()

File.write!(dir <> ".toml", """
data_dir = #{inspect(dir)}

[log]
level = "warning"

[login]
port = #{ports.login}

[world_manager]
port = #{ports.wm}

[zone]
port = #{ports.zone}
""")

System.put_env("PINATA_CONFIG", dir <> ".toml")
System.put_env("PINATA_TEST_DATA_DIR", dir)
{:ok, _apps} = Application.ensure_all_started(:pinata)

# Not ExUnit.after_suite: it runs after every run of --repeat-until-failure, but the data is created once.
System.at_exit(fn _status ->
  File.rm_rf!(dir)
  File.rm!(dir <> ".toml")
end)

Replay.Topology.start()

# Tests tagged :symlink create symlinks. Windows allows that only with the symlink privilege (Developer Mode or an
# elevated shell); without it File.ln_s/2 fails with :eperm, and the tests are excluded.
probe = Path.join(Path.expand(System.tmp_dir!()), "pinata-symlink-probe-#{System.pid()}")
File.rm_rf!(probe)
File.mkdir_p!(probe)

symlink =
  case File.ln_s(probe, Path.join(probe, "link")) do
    :ok ->
      []

    {:error, reason} ->
      IO.puts("Excluding :symlink tests: this user cannot create symlinks (#{:file.format_error(reason)}).")
      [:symlink]
  end

File.rm_rf!(probe)

# Tests tagged :unix_file_modes take the read right away with File.chmod/2. On Windows that does not make a file
# unreadable, so they are excluded there.
file_modes =
  case :os.type() do
    {:win32, _} ->
      IO.puts("Excluding :unix_file_modes tests: Windows has no Unix file modes.")
      [:unix_file_modes]

    {:unix, _} ->
      []
  end

ExUnit.start(exclude: symlink ++ file_modes)
