defmodule Replay.Setups do
  @moduledoc """
  One setup function per capture: it creates the state the capture starts from (accounts, characters).

  Rule of ADR 0008: public `Persistence` operations where one exists, a test-only factory otherwise, no database
  dumps. Every function creates the account `admin` (the client sends the MD5 text of the password); `login_logout/0` and
  `create_char/0` also create the character "Test1235" of their capture; the issues that define the later packets add
  the others.
  """

  @doc "Setup of `re-data/captures/26_11_15_login-logout.md`. The account `admin` and the character `Test1235`."
  @spec login_logout() :: :ok
  def login_logout, do: accounts() |> test1235()

  @doc "Setup of `re-data/captures/26_11_15_login-errors.md`. The account `admin`."
  @spec login_errors() :: :ok
  def login_errors, do: accounts() && :ok

  @doc "Setup of `re-data/captures/26_11_15_create-char.md`. The account `admin` and the character `Test1235`."
  @spec create_char() :: :ok
  def create_char, do: accounts() |> test1235()

  @doc "Setup of `re-data/captures/26_11_15_37_login-heartbeat-refusals-delete.md`. The account `admin`."
  @spec login_heartbeat_refusals_delete() :: :ok
  def login_heartbeat_refusals_delete, do: accounts() && :ok

  @doc "Setup of `re-data/captures/26_11_16_37b_char-select-rename-refusals.md`. The account `admin`."
  @spec char_select_rename_refusals() :: :ok
  def char_select_rename_refusals, do: accounts() && :ok

  defp accounts do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, id} = Persistence.create_account("admin", "21232f297a57a5a743894a0e4a801fc3")
    id
  end

  defp test1235(account_id) do
    character =
      Factory.character(account_id, %{
        id: 2,
        name: "Test1235",
        level: 120,
        race: 2,
        class: 11,
        gender: 1,
        hair: 4,
        kq_map: "RouN",
        kq_x: 6477,
        kq_y: 9844,
        kq_date: ~U[2026-11-13 11:57:15Z]
      })

    for {slot, item_id} <- [{10, 1250}, {8, 35_740}, {25, 30_817}], do: Factory.item(character.id, slot, item_id)
    :ok
  end
end
