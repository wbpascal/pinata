defmodule TestMapTable do
  @moduledoc """
  Test-only: moves a map of the WorldManager map table to another Zone node (`test/gm_command_test.exs`, a kick
  across two Zone nodes). Required on the peers like `test_clock.ex`: a closure cannot cross `:peer.call/4`, an MFA can.
  """

  @doc "Sets the Zone node (its `Zone.Maps` process) of a map in the map table of the world; returns the previous one."
  @spec move(Cluster.Registry.world_id(), String.t(), pid()) :: {:ok, pid()}
  def move(world, map_name, zone_maps) do
    {:ok, wm} = Cluster.Registry.whereis_world_manager(world)
    old = :sys.get_state(wm).maps[map_name]
    :sys.replace_state(wm, &put_in(&1.maps[map_name], zone_maps))
    {:ok, old}
  end
end
