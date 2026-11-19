defmodule Cluster.Login do
  @moduledoc "Facade through which WorldManager calls the Login part (ADR 0002)."

  @doc "Asks Login for a login token of the account. Exits when Login is not registered."
  @spec create_token(pos_integer(), String.t()) :: {:ok, String.t()} | {:error, :pending}
  def create_token(user_no, user_name),
    do: GenServer.call(Cluster.Registry.login(), {:create_token, user_no, user_name})
end
