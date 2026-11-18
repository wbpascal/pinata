defmodule Net.Handler do
  @moduledoc """
  What a part implements to handle the packets of its clients.

  `init/0` returns the session state of a new connection. `handle_packet/2` is pure: session state and a decoded
  packet in, new state and effects out. Heartbeat packets (`0x0804`, `0x0805`) never reach it.
  """

  @type effect :: {:send, struct()}

  @callback init() :: term()
  @callback handle_packet(state :: term(), packet :: struct()) :: {term(), [effect()]}
end
