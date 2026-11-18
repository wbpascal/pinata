defmodule Login.Handler do
  @moduledoc "Packet handler of the Login part. It handles no packet yet."

  @behaviour Net.Handler

  @impl Net.Handler
  def init, do: %{}

  @impl Net.Handler
  def handle_packet(state, _packet), do: {state, []}
end
