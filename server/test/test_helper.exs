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
{:ok, _apps} = Application.ensure_all_started(:pinata)

ExUnit.start()
