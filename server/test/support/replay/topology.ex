defmodule Replay.Topology do
  @moduledoc "Where the replay connects, chosen by the environment variable `PINATA_TEST_TOPOLOGY` (`single` or `multi`)."

  @type endpoints :: %{String.t() => {charlist(), :inet.port_number()}}

  @doc "Endpoint of each connection kind (`login`, `wm`, `zone`)."
  @spec endpoints() :: endpoints()
  def endpoints do
    case System.get_env("PINATA_TEST_TOPOLOGY", "single") do
      # the application test_helper.exs starts, on the default ports
      "single" -> %{"login" => {~c"127.0.0.1", 9010}, "wm" => {~c"127.0.0.1", 9110}, "zone" => {~c"127.0.0.1", 9210}}
      "multi" -> raise "PINATA_TEST_TOPOLOGY=multi (:peer nodes on PostgreSQL) is completed by issue #48"
      other -> raise "PINATA_TEST_TOPOLOGY=#{inspect(other)} is not valid, use \"single\" or \"multi\""
    end
  end
end
