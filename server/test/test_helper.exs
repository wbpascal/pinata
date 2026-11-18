# The custom Credo checks live outside lib/ (Credo is not a production dependency).
"../credo/checks/*.ex" |> Path.expand(__DIR__) |> Path.wildcard() |> Enum.each(&Code.require_file/1)

ExUnit.start()
