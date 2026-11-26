defmodule Mix.Tasks.Pinata.Character.AdminLevel do
  @shortdoc "Sets the admin level of a character"
  @moduledoc """
  Sets the admin level (0 to 255) of a character. Usage:
  `mix pinata.character.admin_level <character name> <level> [--world <n>]`. See `docs/user/gm-commands.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @usage "Usage: mix pinata.character.admin_level <character name> <level> [--world <n>]"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    with {opts, [name, level], []} <- OptionParser.parse(args, strict: [world: :integer]),
         {level, ""} <- Integer.parse(level) do
      Mix.Task.run("app.config")

      try do
        Persistence.Release.set_admin_level(name, level, Keyword.get(opts, :world, :default))
      rescue
        error in RuntimeError -> Mix.raise(error.message)
      end
    else
      _ -> Mix.raise(@usage)
    end
  end
end
