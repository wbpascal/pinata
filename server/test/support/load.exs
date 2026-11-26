# The load run (docs/technical/load-run.md): `MIX_ENV=test mix pinata.load …` runs this file through the alias in mix.exs.
for file <- ["test_client.ex", "replay/transcript.ex", "load/placement.ex", "load/player.ex", "load.ex"],
    do: Code.require_file(file, __DIR__)

Load.main(System.argv())
