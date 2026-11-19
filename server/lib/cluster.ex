defmodule Cluster do
  @moduledoc "Registry and the facades through which parts call each other (ADR 0002)."

  use Boundary, deps: [Settings, Clock, Random], exports: [Root, Registry, Sessions, Login, WorldManager]
end
