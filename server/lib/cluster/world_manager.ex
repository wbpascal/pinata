defmodule Cluster.WorldManager do
  @moduledoc "Facade through which Login and Zone call the WorldManager of a world (ADR 0002)."

  @type login_request :: %{user_no: pos_integer(), user_name: String.t(), validate: [0..0xFFFF]}

  @doc "Reserves a world login at the WorldManager of the world. Exits when the world is not registered."
  @spec expect_login(Cluster.Registry.world_id(), login_request()) :: :ok
  def expect_login(world_id, request),
    do: GenServer.call(Cluster.Registry.world_manager(world_id), {:expect_login, request})

  @doc """
  A Zone node joins the world: `zone` is its `Zone.Maps` process, `address` its own `public_host` and `zone.port`,
  `offered` the maps it can run. The answer is the maps it must run. Exits when the world is not registered.
  """
  @spec join_zone(Cluster.Registry.world_id(), pid(), {String.t(), pos_integer()}, [binary()]) :: [binary()]
  def join_zone(world_id, zone, address, offered),
    do: GenServer.call(Cluster.Registry.world_manager(world_id), {:join_zone, zone, address, offered})
end
