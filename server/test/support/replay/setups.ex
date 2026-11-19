defmodule Replay.Setups do
  @moduledoc """
  One setup function per capture: it creates the state the capture starts from (accounts, characters).

  Rule of ADR 0008: public `Persistence` operations where one exists, a test-only factory otherwise, no database
  dumps. Up to the seed packet no state is needed, so every function does nothing yet; the issues that define
  the later packets fill them.
  """

  @doc "Setup of `re-data/captures/26_11_15_login-logout.md`. Nothing is needed up to the seed packet."
  @spec login_logout() :: :ok
  def login_logout, do: :ok

  @doc "Setup of `re-data/captures/26_11_15_login-errors.md`. Nothing is needed up to the seed packet."
  @spec login_errors() :: :ok
  def login_errors, do: :ok

  @doc "Setup of `re-data/captures/26_11_15_create-char.md`. Nothing is needed up to the seed packet."
  @spec create_char() :: :ok
  def create_char, do: :ok

  @doc "Setup of `re-data/captures/26_11_15_37_login-heartbeat-refusals-delete.md`. Nothing is needed up to the seed packet."
  @spec login_heartbeat_refusals_delete() :: :ok
  def login_heartbeat_refusals_delete, do: :ok

  @doc "Setup of `re-data/captures/26_11_16_37b_char-select-rename-refusals.md`. Nothing is needed up to the seed packet."
  @spec char_select_rename_refusals() :: :ok
  def char_select_rename_refusals, do: :ok
end
