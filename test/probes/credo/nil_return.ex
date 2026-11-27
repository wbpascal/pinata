defmodule Probe.NilReturn do
  @moduledoc false

  @spec find(integer()) :: String.t() | nil
  def find(_id), do: nil

  @spec find_tagged(integer()) :: {:ok, String.t()} | :error
  def find_tagged(id), do: helper(id)

  @spec helper(integer()) :: {:ok, String.t()} | :error
  defp helper(_id), do: :error

  @spec private_lookup(integer()) :: String.t() | nil
  defp private_lookup(_id), do: nil
end
