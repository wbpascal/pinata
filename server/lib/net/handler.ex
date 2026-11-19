defmodule Net.Handler do
  @moduledoc """
  What a part implements to handle the packets of its clients.

  `init/1` returns the session state of a new connection. `handle_packet/2` and `handle_info/2` are pure: session
  state and a decoded packet (or message) in, new state and effects out. Heartbeat packets (`0x0804`, `0x0805`)
  never reach them. `perform/1` is the only impure callback: the connection process calls it for a
  `{:perform, request}` effect and hands its return value to `handle_info/2`. A message `{:cluster, term}` sent to
  the connection process also goes to `handle_info/2`. `:close` closes the socket after the effects before it;
  effects after it are not run.
  """

  @type effect :: {:send, struct()} | :close | {:perform, term()}

  @callback init(settings :: Settings.t()) :: term()
  @callback handle_packet(state :: term(), packet :: struct()) :: {term(), [effect()]}
  @callback handle_info(state :: term(), message :: term()) :: {term(), [effect()]}
  @callback perform(request :: term()) :: term()
  @optional_callbacks handle_info: 2, perform: 1
end
