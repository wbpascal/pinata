defmodule Fiesta.Credo.DirectTimeOrRandom do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      System time and randomness are read only through `Clock` and `Random` (ADR 0008), so that
      capture replay can inject both.
      """
    ]

  @allowed_files ~r{(^|/)lib/(clock|random)(\.ex|/)}

  @any_function [:rand, :random]

  @banned %{
    System => [:system_time, :os_time, :monotonic_time],
    DateTime => [:utc_now, :now, :now!],
    NaiveDateTime => [:utc_now, :local_now],
    Date => [:utc_today],
    Time => [:utc_now],
    Enum => [:random, :shuffle, :take_random],
    :os => [:system_time, :timestamp],
    :erlang => [:system_time, :monotonic_time, :timestamp, :now, :localtime, :universaltime, :date, :time],
    :calendar => [:local_time, :universal_time]
  }

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if source_file.filename =~ @allowed_files do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp traverse({{:., _, [module, function]}, meta, _args} = ast, issues, issue_meta)
       when is_atom(function) do
    module = module_name(module)

    if module in @any_function or function in Map.get(@banned, module, []) do
      {ast, [issue(issue_meta, module, function, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp module_name({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_name(other), do: other

  defp issue(issue_meta, module, function, line) do
    call = "#{inspect(module)}.#{function}"

    format_issue(issue_meta,
      message: "#{call} is called directly; use Clock or Random.",
      trigger: call,
      line_no: line
    )
  end
end
