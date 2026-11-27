defmodule Net do
  @moduledoc "Client sockets: the listener of a part and one connection process per socket (ADR 0009)."

  use Boundary, deps: [Proto, Settings, Clock, Random], exports: [Handler, Listener]
end
