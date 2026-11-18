defmodule GameData do
  @moduledoc "Client and server data tables, loaded once at start-up (ADR 0006)."

  use Boundary, deps: [Clock, Random]
end
