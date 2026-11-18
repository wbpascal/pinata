defmodule Cluster.Registry do
  @moduledoc "Where the parts find each other (ADR 0002): `:global` names and one `:pg` group of Zone nodes per world."

  @type world_id :: non_neg_integer()

  @doc "The `:pg` scope, started by `Cluster.Root`."
  @spec scope() :: atom()
  def scope, do: __MODULE__

  @doc "The name under which the Login part registers its process."
  @spec login() :: {:global, {:login}}
  def login, do: {:global, {:login}}

  @doc "The name under which the WorldManager of a world registers its process."
  @spec world_manager(world_id()) :: {:global, {:world_manager, world_id()}}
  def world_manager(world_id), do: {:global, {:world_manager, world_id}}

  @spec whereis_login() :: {:ok, pid()} | :error
  def whereis_login, do: whereis({:login})

  @spec whereis_world_manager(world_id()) :: {:ok, pid()} | :error
  def whereis_world_manager(world_id), do: whereis({:world_manager, world_id})

  @doc "Adds a process of this Zone node to the group of its world."
  @spec join_zones(world_id(), pid()) :: :ok
  def join_zones(world_id, pid), do: :pg.join(scope(), {:zones, world_id}, pid)

  @spec zones(world_id()) :: [pid()]
  def zones(world_id), do: :pg.get_members(scope(), {:zones, world_id})

  defp whereis(name) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> :error
    end
  end
end
