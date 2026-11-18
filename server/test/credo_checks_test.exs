defmodule Pinata.CredoChecksTest do
  use Credo.Test.Case, async: true

  alias Pinata.Credo.DirectTimeOrRandom
  alias Pinata.Credo.NoNamedTable
  alias Pinata.Credo.NoNilReturn

  defp probe(name, filename \\ "lib/probe.ex") do
    "probes/credo/#{name}.ex" |> Path.expand(__DIR__) |> File.read!() |> to_source_file(filename)
  end

  test "NoNilReturn fires on the public spec only" do
    "nil_return" |> probe() |> run_check(NoNilReturn) |> assert_issue(fn issue -> assert issue.line_no == 4 end)
  end

  test "NoNamedTable fires" do
    "named_table" |> probe() |> run_check(NoNamedTable) |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end

  test "DirectTimeOrRandom fires on system time and on :rand" do
    "time_and_random"
    |> probe()
    |> run_check(DirectTimeOrRandom)
    |> assert_issues(fn issues -> assert Enum.sort(Enum.map(issues, & &1.line_no)) == [5, 8] end)
  end

  test "DirectTimeOrRandom allows Clock and Random" do
    "time_and_random" |> probe("lib/clock/system.ex") |> run_check(DirectTimeOrRandom) |> refute_issues()
    "time_and_random" |> probe("lib/random.ex") |> run_check(DirectTimeOrRandom) |> refute_issues()
  end

  test ".credo.exs enables the three checks" do
    {%{configs: [config]}, _bindings} = Code.eval_file(Path.expand("../.credo.exs", __DIR__))
    enabled = Enum.map(config.checks.extra, &elem(&1, 0))
    assert NoNilReturn in enabled and NoNamedTable in enabled and DirectTimeOrRandom in enabled
  end
end
