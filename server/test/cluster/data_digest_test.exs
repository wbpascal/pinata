defmodule Cluster.DataDigestTest do
  # Starts real nodes, on ports from TestPorts.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "a Zone node with another data directory is refused by the WorldManager node", %{tmp_dir: tmp_dir} do
    peers = TestPeers.start()
    on_exit(fn -> TestPeers.stop(peers) end)

    # the WorldManager peer logs the refusal as an error; it is expected here and would show in the test output
    :ok = :peer.call(peers.wm, Logger, :configure, [[level: :none]])

    # works while Zone.game_data/0 is []; when Zone declares tables, copy the test data directory and change one file
    bad_dir = Path.join(tmp_dir, "data")
    File.mkdir_p!(bad_dir)
    File.write!(Path.join(bad_dir, "x.txt"), "x")

    config = Path.join(tmp_dir, "pinata.toml")
    [zone_port] = TestPorts.free(1)

    File.write!(config, """
    data_dir = #{inspect(bad_dir)}

    [zone]
    port = #{zone_port}

    [cluster]
    nodes = [#{inspect(to_string(peers.nodes.wm))}]
    """)

    # halts itself with status 3 after 30 s if it is never refused, so the test cannot hang
    script =
      "Application.put_env(:pinata, :sqlite_in_multi_node, true); " <>
        "case Application.ensure_all_started(:pinata) do {:ok, _} -> Process.sleep(30_000); System.halt(3); _ -> System.halt(4) end"

    args =
      ["--name", "pinata_bad_#{System.pid()}@127.0.0.1", "--cookie", "pinata_test"] ++
        Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)]) ++ ["-e", script]

    {output, status} =
      System.cmd(System.find_executable("elixir"), args,
        env: [{"PINATA_PARTS", "zone"}, {"PINATA_CONFIG", config}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "Data directory digest mismatch"
    assert output =~ GameData.digest(bad_dir)
    assert output =~ GameData.digest(System.fetch_env!("PINATA_TEST_DATA_DIR"))
    assert {:ok, _} = :peer.call(peers.wm, Cluster.Registry, :whereis_world_manager, [0])
  end
end
