defmodule Replay.Setups do
  @moduledoc """
  One setup function per capture: it creates the state the capture starts from (accounts, characters).

  Rule of ADR 0008: public `Persistence` operations where one exists, a test-only factory otherwise, no database
  dumps. Every function creates the account `admin` (the client sends the MD5 text of the password); the issues
  that define the later packets add characters.
  """

  @doc "Setup of `re-data/captures/26_11_15_login-logout.md`. The account `admin`."
  @spec login_logout() :: :ok
  def login_logout, do: accounts()

  @doc "Setup of `re-data/captures/26_11_15_login-errors.md`. The account `admin`."
  @spec login_errors() :: :ok
  def login_errors, do: accounts()

  @doc "Setup of `re-data/captures/26_11_15_create-char.md`. The account `admin`."
  @spec create_char() :: :ok
  def create_char, do: accounts()

  @doc "Setup of `re-data/captures/26_11_15_37_login-heartbeat-refusals-delete.md`. The account `admin`."
  @spec login_heartbeat_refusals_delete() :: :ok
  def login_heartbeat_refusals_delete, do: accounts()

  @doc "Setup of `re-data/captures/26_11_16_37b_char-select-rename-refusals.md`. The account `admin`."
  @spec char_select_rename_refusals() :: :ok
  def char_select_rename_refusals, do: accounts()

  defp accounts do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, _} = Persistence.create_account("admin", "21232f297a57a5a743894a0e4a801fc3")
    :ok
  end
end
