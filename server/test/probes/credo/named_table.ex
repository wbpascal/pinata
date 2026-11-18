defmodule Probe.NamedTable do
  @moduledoc false

  @spec create() :: :ets.table()
  def create, do: :ets.new(:probe, [:set, :named_table])
end
