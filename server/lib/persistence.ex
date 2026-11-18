defmodule Persistence do
  @moduledoc "Database access: one function per business operation (ADR 0004)."

  use Boundary, deps: [Clock, Random]
end
