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

    GameData.Release.import_data(source, target)
  rescue
    error in RuntimeError -> Mix.raise(error.message)
  end

  def run(_args), do: Mix.raise("usage: mix pinata.import_data <9Data folder> <new data directory>")
end
