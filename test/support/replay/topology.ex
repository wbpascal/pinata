defmodule Replay.Topology do
  @moduledoc """
  Where the replay connects, chosen by the environment variable `PINATA_TEST_TOPOLOGY` (`single` or `multi`).
  `start/0` runs once from `test_helper.exs`; `multi` starts the three `TestPeers`; all ports come from `TestPorts`.
  """

  @type endpoints :: %{String.t() => {charlist(), :inet.port_number()}}
  @type part :: :login | :wm | :zone

  @doc "The topology named by a value of the environment variable."
  @spec mode(String.t() | nil) :: :single | :multi
  def mode(nil), do: :single
  def mode("single"), do: :single
  def mode("multi"), do: :multi
  def mode(other), do: raise("PINATA_TEST_TOPOLOGY=#{inspect(other)} is not valid, use \"single\" or \"multi\"")

  @doc "Starts the peers of `multi` and remembers them; `single` uses the application of the test VM."
  @spec start() :: :ok
  def start do
    peers =
      case mode(System.get_env("PINATA_TEST_TOPOLOGY")) do
        :single ->
          %{}

        :multi ->
          peers = TestPeers.start()
          System.at_exit(fn _status -> TestPeers.stop(peers) end)
          peers
      end

    :persistent_term.put(__MODULE__, peers)
  end

  @doc "Endpoint of each connection kind (`login`, `wm`, `zone`)."
  @spec endpoints() :: endpoints()
  def endpoints do
    case :persistent_term.get(__MODULE__, %{}) do
      %{login_port: login, wm_port: wm, zone_port: zone} ->
        %{"login" => {~c"127.0.0.1", login}, "wm" => {~c"127.0.0.1", wm}, "zone" => {~c"127.0.0.1", zone}}

      %{} ->
        # the application test_helper.exs starts
        %{"login" => TestPorts.endpoint(:login), "wm" => TestPorts.endpoint(:wm), "zone" => TestPorts.endpoint(:zone)}
    end
  end

  @doc "Calls a function on the node of a part: in this VM for `single`, on the peer for `multi`."
  @spec call(part(), module(), atom(), [term()]) :: term()
  def call(part, module, function, args) do
    case :persistent_term.get(__MODULE__, %{}) do
      %{^part => peer} -> :peer.call(peer, module, function, args)
      %{} -> apply(module, function, args)
    end
  end

  @doc "Calls a function in this VM and on every peer (the test clock lives in each VM)."
  @spec all(module(), atom(), [term()]) :: :ok
  def all(module, function, args) do
    _ = apply(module, function, args)

    for {part, peer} <- :persistent_term.get(__MODULE__, %{}), part in [:login, :wm, :zone] do
      :peer.call(peer, module, function, args)
    end

    :ok
  end
end
