defmodule Cluster.WorldManager do
  @moduledoc "Facade through which Login calls the WorldManager of a world (ADR 0002)."

  @type login_request :: %{user_no: pos_integer(), user_name: String.t(), validate: [0..0xFFFF]}

  @doc "Reserves a world login at the WorldManager of the world. Exits when the world is not registered."
  @spec expect_login(Cluster.Registry.world_id(), login_request()) :: :ok
  def expect_login(world_id, request),
    do: GenServer.call(Cluster.Registry.world_manager(world_id), {:expect_login, request})
end
