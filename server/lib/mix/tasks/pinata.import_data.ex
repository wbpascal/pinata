defmodule Mix.Tasks.Pinata.ImportData do
  @shortdoc "Creates a data directory from an original 9Data folder"
  @moduledoc """
  Usage: `mix pinata.import_data <9Data folder> <new data directory>`

  Turns an original `9Data` folder into the data directory of this server (ADR 0005): SHN tables, scripts and
  geometry are copied, the TXT tables and the character-default scripts become CSV files. The target must not exist
  or must be empty. Set `data_dir` in `pinata.toml` to the new directory afterwards.
  """

  use Boundary, classify_to: GameData
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([source, target]) do
    Mix.Task.run("app.config")

    case GameData.Import.run(source, target) do
      {:ok, report} ->
        Enum.each(report.warnings, &Mix.shell().info("warning: #{&1}"))

        Mix.shell().info(
          "Imported #{source} into #{target}: #{report.tables} tables written as CSV, #{report.copied} files copied, " <>
            "#{length(report.skipped)} files left out."
        )

        Mix.shell().info("Next: set data_dir = #{inspect(target)} in pinata.toml.")

      {:error, problems} ->
        Mix.raise(Enum.join(problems, "\n"))
    end
  end

  def run(_args), do: Mix.raise("usage: mix pinata.import_data <9Data folder> <new data directory>")
end
