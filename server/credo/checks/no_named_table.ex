defmodule Fiesta.Credo.NoNamedTable do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Named ETS tables are banned (ADR 0001): `boundary` cannot see ETS access.

      An unnamed table is reachable only through the table id its owner holds.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    {_line, issues} = Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), {1, []})
    issues
  end

  # A bare atom carries no line, so report the line of the last node seen before it.
  defp traverse({_, meta, _} = ast, {line, issues}, _issue_meta) when is_list(meta) do
    {ast, {meta[:line] || line, issues}}
  end

  defp traverse(:named_table, {line, issues}, issue_meta) do
    issue =
      format_issue(issue_meta,
        message: "Named ETS tables are banned; keep the table id in the owning process.",
        trigger: ":named_table",
        line_no: line
      )

    {:named_table, {line, [issue | issues]}}
  end

  defp traverse(ast, acc, _issue_meta), do: {ast, acc}
end
