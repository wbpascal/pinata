defmodule WorkflowTest do
  # Enters a map instance of the running application.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @workflow Path.expand("../.github/workflows/server.yml", __DIR__)
  @agents Path.expand("../AGENTS.md", __DIR__)
  @support Path.expand("support", __DIR__)

  test "AGENTS.md has one row per job of server.yml" do
    [_head, jobs] = @workflow |> File.read!() |> String.split("\njobs:\n", parts: 2)
    [_before, rest] = @agents |> File.read!() |> String.split("\n## CI jobs\n", parts: 2)
    [section | _later] = String.split(rest, "\n## ", parts: 2)

    in_workflow = for [_, name] <- Regex.scan(~r/^  ([\w-]+):\s*$/m, jobs), do: name
    in_table = for [_, name] <- Regex.scan(~r/^\| `([\w-]+)` \|/m, section), do: name

    assert in_workflow != []
    assert in_workflow -- in_table == [], "jobs of server.yml without a row in the table"
    assert in_table -- in_workflow == [], "rows of the table that name no job of server.yml"
  end

  test "the scripts of the otel-smoke job run" do
    assert capture_io(fn -> Code.eval_file("otel_apps.exs", @support) end) =~ "["

    {{map, handle, conn}, _bindings} = Code.eval_file("otel_enter.exs", @support)
    assert {:ok, %Zone.Player{conn: ^conn}} = Zone.MapInstance.leave(map, handle)
    Process.exit(conn, :kill)
  end
end
