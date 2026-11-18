defmodule Fiesta.BoundaryTest do
  use ExUnit.Case, async: true

  @moduletag timeout: 300_000

  # Compiles the project again with test/probes/boundary added (see elixirc_paths in mix.exs),
  # into its own build directory so the running build stays untouched.
  test "boundary rejects a reference from one part to another" do
    root = Path.expand("..", __DIR__)

    env = [
      {"FIESTA_BOUNDARY_PROBE", "1"},
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", Path.join(root, "_build/boundary_probe")}
    ]

    {output, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"], cd: root, env: env, stderr_to_stdout: true)

    assert status != 0
    assert output =~ "forbidden reference to Login"
    assert output =~ "references from Zone to Login are not allowed"
  end
end
