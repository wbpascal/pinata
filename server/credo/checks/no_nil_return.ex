defmodule Fiesta.Credo.NoNilReturn do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      A public function never returns `value | nil` (ADR 0003).

      Return `{:ok, value} | :error` from a lookup and `{:ok, value} | {:error, reason}` from an
      operation that can fail.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    {specs, private} = Credo.Code.prewalk(source_file, &collect/2, {[], MapSet.new()})

    for {name, arity, line} <- specs, not MapSet.member?(private, {name, arity}) do
      format_issue(issue_meta,
        message: "Public @spec #{name}/#{arity} returns `| nil`; return a tagged result instead.",
        trigger: "@spec",
        line_no: line
      )
    end
  end

  defp collect({:@, meta, [{:spec, _, [spec]}]} = ast, {specs, private}) do
    case spec_head(spec) do
      {{name, _, args}, return} when is_atom(name) ->
        if nil in union(return) do
          {ast, {[{name, arity(args), meta[:line]} | specs], private}}
        else
          {ast, {specs, private}}
        end

      _other ->
        {ast, {specs, private}}
    end
  end

  # shortcut: a defp with default arguments is matched on its full arity only
  defp collect({:defp, _, [head | _]} = ast, {specs, private}) do
    {name, _, args} = def_head(head)
    {ast, {specs, MapSet.put(private, {name, arity(args)})}}
  end

  defp collect(ast, acc), do: {ast, acc}

  defp spec_head({:when, _, [spec, _guards]}), do: spec_head(spec)
  defp spec_head({:"::", _, [head, return]}), do: {head, return}
  defp spec_head(_other), do: :error

  defp def_head({:when, _, [head | _]}), do: head
  defp def_head(head), do: head

  defp union({:|, _, [left, right]}), do: union(left) ++ union(right)
  defp union(type), do: [type]

  defp arity(args) when is_list(args), do: length(args)
  defp arity(_no_args), do: 0
end
