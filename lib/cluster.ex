defmodule Cluster do
  @moduledoc "Registry and the facades through which parts call each other (ADR 0002)."

  use Boundary, deps: [Settings, Clock, Random], exports: [Root, DataDigest, Registry, Sessions, Login, WorldManager]
end
