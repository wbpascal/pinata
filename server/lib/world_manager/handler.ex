defmodule WorldManager.Handler do
  @moduledoc "Packet handler of the WorldManager part. It handles no packet yet."

  @behaviour Net.Handler

  @impl Net.Handler
  def init(_settings), do: %{}

  @impl Net.Handler
  def handle_packet(state, _packet), do: {state, []}
end
