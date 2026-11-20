defmodule TestPeers do
  @moduledoc """
  Three `:peer` nodes for the multi-node tests: one runs the Login part, one the WorldManager part, one the Zone
  part. They share the settings file and the database of the test VM and talk to each other through `:global` and `:pg`.

  The test VM is not distributed and not connected to them, so the control connection is standard I/O.
  """

  @call_timeout 30_000

  @type t :: %{
          login: pid(),
          wm: pid(),
          zone: pid(),
          login_port: :inet.port_number(),
          wm_port: :inet.port_number(),
          zone_port: :inet.port_number(),
          nodes: %{login: node(), wm: node(), zone: node()},
          config: Path.t()
        }

  @doc "Starts the three peers and connects them. The client ports come from `TestPorts.pick/0`."
  @spec start() :: t()
  def start do
    ports = TestPorts.pick()
    config = Path.join(System.tmp_dir!(), "pinata-peers-#{System.pid()}-#{System.unique_integer([:positive])}.toml")
    File.write!(config, "data_dir = #{inspect(System.fetch_env!("PINATA_TEST_DATA_DIR"))}\n" <> TestPorts.toml(ports))

    {login, login_node} = start_peer("login", "login", config)
    {wm, wm_node} = start_peer("world_manager", "world_manager", config)
    {zone, zone_node} = start_peer("zone", "zone", config)
    true = :peer.call(login, Node, :connect, [wm_node])
    true = :peer.call(zone, Node, :connect, [wm_node])
    _ = :peer.call(login, :global, :sync, [], @call_timeout)

    %{
      login: login,
      wm: wm,
      zone: zone,
      login_port: ports.login,
      wm_port: ports.wm,
      zone_port: ports.zone,
      nodes: %{login: login_node, wm: wm_node, zone: zone_node},
      config: config
    }
  end

  @doc "Stops the three peers and deletes the settings file."
  @spec stop(t()) :: :ok
  def stop(%{login: login, wm: wm, zone: zone, config: config}) do
    Enum.each([login, wm, zone], &:peer.stop/1)
    File.rm(config)
    :ok
  end

  defp start_peer(label, parts, config) do
    {:ok, pid, node} =
      :peer.start(%{
        name: :peer.random_name(~c"pinata_#{label}"),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", ~c"pinata_test"],
        env: [{~c"PINATA_PARTS", String.to_charlist(parts)}, {~c"PINATA_CONFIG", String.to_charlist(config)}]
      })

    :ok = :peer.call(pid, :code, :add_paths, [:code.get_path()])
    :ok = :peer.call(pid, Application, :put_env, [:pinata, :password_iterations, 1_000])
    :ok = :peer.call(pid, Application, :put_env, [:pinata, :sqlite_in_multi_node, true])
    {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [:logger])
    :ok = :peer.call(pid, Logger, :configure, [[level: :warning]])

    _ = :peer.call(pid, Code, :require_file, [Path.expand("test_clock.ex", __DIR__)], @call_timeout)

    {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [:pinata], @call_timeout)
    {pid, node}
  end
end
