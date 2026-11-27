defmodule Login.Tokens do
  @moduledoc """
  The registered process of the Login part (`Cluster.Registry.login/0`): it holds the login tokens WorldManager
  asks for when a client goes back to the world list (flow: `docs/technical/flows/return-to-world-list.md`).

  A token is 32 hex characters, good for one use and valid for 10 s. An account has at most one pending token.
  Every call first removes all expired tokens (L01-B9 fixed).
  """

  use GenServer

  @ttl_ms 10_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: Cluster.Registry.login())

  @doc "Uses up the token. `:error` when it is unknown, used or expired."
  @spec take(String.t()) :: {:ok, {pos_integer(), String.t()}} | :error
  def take(token), do: GenServer.call(Cluster.Registry.login(), {:take_token, token})

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:create_token, user_no, user_name}, _from, state) do
    now = Clock.monotonic_time(:millisecond)
    fresh = fresh(state, now)

    if Enum.any?(fresh, fn {_token, {no, _name, _at}} -> no == user_no end) do
      {:reply, {:error, :pending}, fresh}
    else
      token = Base.encode16(Random.bytes(16), case: :lower)
      {:reply, {:ok, token}, Map.put(fresh, token, {user_no, user_name, now})}
    end
  end

  def handle_call({:take_token, token}, _from, state) do
    fresh = fresh(state, Clock.monotonic_time(:millisecond))

    case Map.pop(fresh, token) do
      {{user_no, user_name, _at}, rest} -> {:reply, {:ok, {user_no, user_name}}, rest}
      {nil, rest} -> {:reply, :error, rest}
    end
  end

  defp fresh(state, now), do: Map.filter(state, fn {_token, {_no, _name, at}} -> now - at < @ttl_ms end)
end
