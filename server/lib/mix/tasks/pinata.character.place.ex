defmodule Mix.Tasks.Pinata.Character.Place do
  @shortdoc "Sets the stored map and position of characters (name,map,x,y lines on standard input)"
  @moduledoc """
  Sets the stored map and position of characters from `name,map,x,y` lines on standard input (the load run).
  Usage: `mix pinata.character.place < <file>`. See `docs/user/accounts.md` and `docs/technical/load-run.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]) do
    Mix.Task.run("app.config")

    try do
      Persistence.Release.place_characters()
    rescue
      error in RuntimeError -> Mix.raise(error.message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix pinata.character.place < <file with name,map,x,y lines>")
end
