defmodule Net.Handler do
  @moduledoc """
  What a part implements to handle the packets of its clients.

  `init/1` returns the session state of a new connection. `handle_packet/2` and `handle_info/2` are pure: session
  state and a decoded packet (or message) in, new state and effects out. Heartbeat packets (`0x0804`, `0x0805`)
  never reach them. `perform/1` is the only impure callback: the connection process calls it for a
  `{:perform, request}` effect and hands its return value to `handle_info/2`. A message `{:cluster, term}` sent to
  the connection process also goes to `handle_info/2`. `GenServer.call(connection, {:cluster, request})` goes to
  `handle_call/2`; its reply is sent after the effects ran. A `:DOWN` of a process the handler monitored (in
  `perform/1`) goes to `handle_info/2` as `{:down, pid}`. `{:close, level, reason}` closes the socket after the effects
  before it and writes the close line; effects after it are not run. `{:log, level, message}` writes a line. The
  connection adds the part and the peer address to both. A message never holds a password, a token or a world key.
  """

  @type level :: :debug | :info | :warning
  @type effect ::
          {:send, struct()} | {:log, level(), String.t()} | {:close, level(), String.t()} | {:perform, term()}

  @callback init(settings :: Settings.t()) :: term()
  @callback handle_packet(state :: term(), packet :: struct()) :: {term(), [effect()]}
  @callback handle_info(state :: term(), message :: term()) :: {term(), [effect()]}
  @callback handle_call(state :: term(), request :: term()) :: {reply :: term(), term(), [effect()]}
  @callback perform(request :: term()) :: term()
  @optional_callbacks handle_info: 2, handle_call: 2, perform: 1
end
