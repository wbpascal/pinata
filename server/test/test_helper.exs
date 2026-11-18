# The custom Credo checks live outside lib/ (Credo is not a production dependency).
"../credo/checks/*.ex" |> Path.expand(__DIR__) |> Path.wildcard() |> Enum.each(&Code.require_file/1)

# Under `mix check` the credo step may already have started the app, so the result is ignored.
_ = Application.ensure_all_started(:credo)

ExUnit.start()
