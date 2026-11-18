defmodule RandomTest do
  use ExUnit.Case, async: false

  defmodule Fixed do
    @behaviour Random.Source

    @impl Random.Source
    def uniform(n), do: n

    @impl Random.Source
    def bytes(n), do: :binary.copy(<<7>>, n)
  end

  test "draws from :rand by default" do
    assert Random.uniform(6) in 1..6
  end

  test "draws from the injected source" do
    Application.put_env(:pinata, :random_source, Fixed)
    on_exit(fn -> Application.delete_env(:pinata, :random_source) end)

    assert Random.uniform(6) == 6
  end

  test "draws bytes from :crypto by default" do
    assert byte_size(Random.bytes(16)) == 16
  end

  test "draws bytes from the injected source" do
    Application.put_env(:pinata, :random_source, Fixed)
    on_exit(fn -> Application.delete_env(:pinata, :random_source) end)

    assert Random.bytes(3) == <<7, 7, 7>>
  end
end
