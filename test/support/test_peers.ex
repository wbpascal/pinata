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

  @doc """
  Starts the three peers and connects them. Their client ports come from `TestPorts.free/1`, chosen after the peer VMs
  are up: each VM binds its distribution listener on port 0, which on Linux could take a port chosen before.
  """
  @spec start() :: t()
  def start do
    config = Path.join(System.tmp_dir!(), "pinata-peers-#{System.pid()}-#{System.unique_integer([:positive])}.toml")
    {login, login_node} = boot_peer("login", "login", config)
    {wm, wm_node} = boot_peer("world_manager", "world_manager", config)
    {zone, zone_node} = boot_peer("zone", "zone", config)
    [login_port, wm_port, zone_port] = TestPorts.free(3)

    File.write!(config, """
    data_dir = #{inspect(System.fetch_env!("PINATA_TEST_DATA_DIR"))}

    [log]
    level = "warning"

    [login]
    port = #{login_port}

    [world_manager]
    port = #{wm_port}

    [zone]
    port = #{zone_port}
    """)

    Enum.each([login, wm, zone], &start_app/1)
    true = :peer.call(login, Node, :connect, [wm_node])
    true = :peer.call(zone, Node, :connect, [wm_node])
    _ = :peer.call(login, :global, :sync, [], @call_timeout)
    wait_for_map_table(wm)

    %{
      login: login,
      wm: wm,
      zone: zone,
      login_port: login_port,
      wm_port: wm_port,
      zone_port: zone_port,
      nodes: %{login: login_node, wm: wm_node, zone: zone_node},
      config: config
    }
  end

  @doc "Stops the three peers and deletes the settings file."
  @spec stop(t()) :: :ok
  def stop(%{login: login, wm: wm, zone: zone, config: config}) do
    # Otherwise the survivors print "node lost" for each peer that stops first.
    peers = [login, wm, zone]
    Enum.each(peers, &:peer.call(&1, Logger, :configure, [[level: :none]]))
    Enum.each(peers, &:peer.stop/1)
    File.rm(config)
    :ok
  end

  @type zone :: %{pid: pid(), node: node(), port: :inet.port_number(), config: Path.t()}

  @doc """
  Boots one more Zone peer with its own client port and connects it to the WorldManager peer. It joins with no maps:
  the first Zone peer runs every map. Move a map to it with `TestMapTable.move/3` on the WorldManager peer.
  """
  @spec add_zone(t()) :: zone()
  def add_zone(peers) do
    config = Path.rootname(peers.config) <> "-zone2.toml"
    {pid, node} = boot_peer("zone2", "zone", config)
    [port] = TestPorts.free(1)
    first = File.read!(peers.config)
    File.write!(config, String.replace(first, "[zone]\nport = #{peers.zone_port}", "[zone]\nport = #{port}"))
    start_app(pid)
    true = :peer.call(pid, Node, :connect, [peers.nodes.wm])
    wait_joined(pid)
    %{pid: pid, node: node, port: port, config: config}
  end

  @doc "Stops a Zone peer of `add_zone/1` and deletes its settings file; the other peers log nothing for it."
  @spec stop_zone(t(), zone()) :: :ok
  def stop_zone(peers, %{pid: pid, node: node, config: config}) do
    others = [peers.login, peers.wm, peers.zone]
    Enum.each(others, &:peer.call(&1, Logger, :configure, [[level: :error]]))
    :ok = :peer.call(pid, Logger, :configure, [[level: :none]])
    :peer.stop(pid)
    wait_lost(peers.wm, node)
    # the other peers see the node go a moment later
    Process.sleep(100)
    Enum.each(others, &:peer.call(&1, Logger, :configure, [[level: :warning]]))
    File.rm(config)
    :ok
  end

  defp wait_joined(pid, tries \\ 100) do
    case :peer.call(pid, :sys, :get_state, [Zone.Maps]) do
      %{worlds: worlds} when map_size(worlds) > 0 -> :ok
      _ when tries > 0 -> Process.sleep(100) && wait_joined(pid, tries - 1)
      _ -> raise "the second Zone peer did not join the WorldManager"
    end
  end

  defp wait_lost(wm, node, tries \\ 100) do
    {:ok, world} = :peer.call(wm, Cluster.Registry, :whereis_world_manager, [0])
    zones = :peer.call(wm, :sys, :get_state, [world]).zones

    cond do
      not Enum.any?(Map.keys(zones), &(node(&1) == node)) -> :ok
      tries > 0 -> Process.sleep(20) && wait_lost(wm, node, tries - 1)
      true -> raise "the WorldManager peer did not see the second Zone peer go"
    end
  end

  # The Zone peer started before it was connected and joins by its 1 s retry.
  defp wait_for_map_table(wm, tries \\ 100) do
    case :peer.call(wm, WorldManager.World, :zone_of, [0, "Rou"]) do
      {:ok, _} -> :ok
      :error when tries > 0 -> Process.sleep(100) && wait_for_map_table(wm, tries - 1)
      :error -> raise "the Zone peer did not join the WorldManager"
    end
  end

  defp boot_peer(label, parts, config) do
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
    _ = :peer.call(pid, Code, :require_file, [Path.expand("test_map_table.ex", __DIR__)], @call_timeout)
    _ = :peer.call(pid, Code, :require_file, [Path.expand("test_random_spot.ex", __DIR__)], @call_timeout)
    {pid, node}
  end

  defp start_app(pid) do
    {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [:pinata], @call_timeout)
  end
end
