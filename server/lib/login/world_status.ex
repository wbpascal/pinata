defmodule Login.WorldStatus do
  @moduledoc """
  The status byte of a world in the world list, from the load of its WorldManager
  (`SetWorldManagerConnectInfo` @ FUN_0040a0c0, `docs/pseudocode/login/L01-process.md` section 3).
  """

  @max_users 2500

  @doc "0 when the world's WorldManager is not registered, else 5 (full) or 6 to 10 by the player count."
  @spec status(registered? :: boolean(), player_count :: non_neg_integer()) :: 0 | 5..10
  def status(false, _count), do: 0
  def status(true, count) when count >= div(95 * @max_users, 100), do: 5
  def status(true, count) when count >= div(30 * @max_users, 100), do: 10
  def status(true, count) when count >= div(10 * @max_users, 100), do: 9
  def status(true, count) when count >= div(8 * @max_users, 100), do: 8
  def status(true, count) when count >= div(5 * @max_users, 100), do: 7
  def status(true, _count), do: 6
end
