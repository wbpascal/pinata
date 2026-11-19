# The custom Credo checks live outside lib/ (Credo is not a production dependency).
"../credo/checks/*.ex" |> Path.expand(__DIR__) |> Path.wildcard() |> Enum.each(&Code.require_file/1)

# Under `mix check` the credo step leaves Credo.Supervisor running although `mix test` stopped the app;
# starting it again would print "already started" notices.
if Process.whereis(Credo.Supervisor) == nil, do: {:ok, _} = Application.ensure_all_started(:credo)

# `mix test` runs with --no-start (alias in mix.exs): the database is chosen here, then the application starts.
_ = Application.stop(:pinata)
{:ok, _apps} = Application.ensure_all_started(:logger)
Application.put_env(:pinata, :password_iterations, 1_000)

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

dir = Path.join(System.tmp_dir!(), "pinata-test-data-#{System.pid()}")
File.rm_rf!(dir)
{:ok, _report} = GameData.Import.run(source, dir)
File.write!(dir <> ".toml", "data_dir = #{inspect(dir)}\n")
System.put_env("PINATA_CONFIG", dir <> ".toml")
System.put_env("PINATA_TEST_DATA_DIR", dir)
{:ok, _apps} = Application.ensure_all_started(:pinata)

# Not ExUnit.after_suite: it runs after every run of --repeat-until-failure, but the data is created once.
System.at_exit(fn _status ->
  File.rm_rf!(dir)
  File.rm!(dir <> ".toml")
end)

# Test client and replay harness (docs/technical/testing.md).
{:ok, _modules, _diagnostics} =
  "support/**/*.ex"
  |> Path.expand(__DIR__)
  |> Path.wildcard()
  |> Kernel.ParallelCompiler.require(return_diagnostics: true)

Replay.Topology.start()

ExUnit.start()
