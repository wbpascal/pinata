defmodule GameData.Release do
  @moduledoc """
  The data import without Mix, for a release: `bin/pinata eval 'GameData.Release.import_data("<9Data folder>", "<new data directory>")'`.
  `mix pinata.import_data` calls it too. It raises `RuntimeError` with the problems on failure, so the exit status is non-zero.
  """

  @spec import_data(Path.t(), Path.t()) :: :ok
  def import_data(source, target) do
    case GameData.Import.run(source, target) do
      {:ok, report} ->
        Enum.each(report.warnings, &IO.puts("warning: #{&1}"))

        IO.puts(
          "Imported #{source} into #{target}: #{report.tables} tables written as CSV, #{report.copied} files copied, " <>
            "#{length(report.skipped)} files left out."
        )

        IO.puts("Next: set data_dir = #{inspect(target)} in pinata.toml.")

      {:error, problems} ->
        raise Enum.join(problems, "\n")
    end
  end
end
