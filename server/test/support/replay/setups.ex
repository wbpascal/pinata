defmodule Replay.Setups do
  @moduledoc """
  One setup function per capture: it creates the state the capture starts from (accounts, characters).

  Rule of ADR 0008: public `Persistence` operations where one exists, a test-only factory otherwise, no database
  dumps. Every function creates the account `admin` (the client sends the MD5 text of the password); `login_logout/0`, `create_char/0` and
  `login_heartbeat_refusals_delete/0` also create the characters of their capture; the issues that define the later
  packets add the others.
  """

  @doc "Setup of `re-data/captures/26_11_15_login-logout.md`. The account `admin` and the character `Test1235`."
  @spec login_logout() :: :ok
  def login_logout, do: accounts() |> test1235()

  @doc "Setup of `re-data/captures/26_11_15_login-errors.md`. The account `admin`."
  @spec login_errors() :: :ok
  def login_errors do
    _ = accounts()
    :ok
  end

  @doc "Setup of `re-data/captures/26_11_15_create-char.md`. The account `admin` and the character `Test1235`."
  @spec create_char() :: :ok
  def create_char, do: accounts() |> test1235()

  @doc """
  Setup of `re-data/captures/26_11_15_37_login-heartbeat-refusals-delete.md`. The account `admin` and the characters
  `Test1235` and `Test2`.
  """
  @spec login_heartbeat_refusals_delete() :: :ok
  def login_heartbeat_refusals_delete do
    account_id = accounts()

    :ok =
      test1235(account_id, %{kq_x: 6502, kq_y: 10_199, kq_date: ~U[2026-11-15 09:44:23Z]}, [{10, 1250}])

    test2 =
      Factory.character(account_id, %{
        id: 5,
        slot: 1,
        name: "Test2",
        level: 8,
        race: 1,
        class: 6,
        hair: 2,
        hair_color: 1,
        face: 4,
        kq_map: "RouN",
        kq_x: 6652,
        kq_y: 8601,
        kq_date: ~U[2026-11-15 11:06:59Z]
      })

    _ = Factory.item(test2.id, 12, 751)
    :ok
  end

  @doc "Setup of `re-data/captures/26_11_16_37b_char-select-rename-refusals.md`. The account `admin`."
  @spec char_select_rename_refusals() :: :ok
  def char_select_rename_refusals do
    _ = accounts()
    :ok
  end

  defp accounts do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, id} = Persistence.create_account("admin", "21232f297a57a5a743894a0e4a801fc3")
    id
  end

  # "Test1235" as in `login-logout` and `create-char`; a later capture overrides what changed since.
  defp test1235(
         account_id,
         attrs \\ %{kq_x: 6477, kq_y: 9844, kq_date: ~U[2026-11-13 11:57:15Z]},
         items \\ [{10, 1250}, {8, 35_740}, {25, 30_817}]
       ) do
    character =
      Factory.character(
        account_id,
        Map.merge(%{id: 2, name: "Test1235", level: 120, race: 2, class: 11, gender: 1, hair: 4, kq_map: "RouN"}, attrs)
      )

    for {slot, item_id} <- items, do: Factory.item(character.id, slot, item_id)
    :ok
  end
end
