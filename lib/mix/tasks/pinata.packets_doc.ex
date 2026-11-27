defmodule Mix.Tasks.Pinata.PacketsDoc do
  @shortdoc "Writes docs/technical/packets.md from the packet definitions"
  @moduledoc """
  Writes `docs/technical/packets.md`. Run it after every change to a packet definition or to
  `Proto.Packets`; `mix check` fails while the file is stale.
  """

  use Boundary, classify_to: Proto
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.config")
    File.write!("docs/technical/packets.md", Proto.PacketsDoc.render())
  end
end
