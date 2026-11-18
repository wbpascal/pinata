defmodule Zone.BoundaryProbe do
  @moduledoc false

  @spec forbidden() :: module()
  def forbidden, do: Login.module_info(:module)
end
