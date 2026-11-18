defmodule RandomTest do
  use ExUnit.Case, async: false

  defmodule Fixed do
    @behaviour Random.Source

    @impl Random.Source
    def uniform(n), do: n
  end

  test "draws from :rand by default" do
    assert Random.uniform(6) in 1..6
  end

  test "draws from the injected source" do
    Application.put_env(:pinata, :random_source, Fixed)
    on_exit(fn -> Application.delete_env(:pinata, :random_source) end)

    assert Random.uniform(6) == 6
  end
end
