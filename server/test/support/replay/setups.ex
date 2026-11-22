defmodule Replay.Setups do
  @moduledoc """
  One setup function per capture: it creates the state the capture starts from (accounts, characters).

  Rule of ADR 0008: public `Persistence` operations where one exists, a test-only factory otherwise, no database
  dumps. Every function creates the account `admin` (the client sends the MD5 text of the password) and the
  characters its capture starts with.
  """

  @doc "Setup of `re-data/captures/26_11_15_login-logout.md`. The account `admin` and the character `Test1235`."
  @spec login_logout() :: :ok
  def login_logout, do: accounts() |> test1235()

  @doc "Setup of `re-data/captures/26_11_15_login-errors.md`. The account `admin` and the character `Test1235`."
  @spec login_errors() :: :ok
  def login_errors, do: accounts() |> test1235()

  @doc "Setup of `re-data/captures/26_11_15_create-char.md`. The account `admin` and the character `Test1235`."
  @spec create_char() :: :ok
  def create_char, do: accounts() |> test1235()

  @doc """
  Setup of `re-data/captures/26_11_15_37_login-heartbeat-refusals-delete.md`. The account `admin` with the characters
  `Test1235` and `Test2`, and account B `testaccountB` (blocked, then not login-able, by the test).
  """
  @spec login_heartbeat_refusals_delete() :: :ok
  def login_heartbeat_refusals_delete do
    account_id = accounts()
    {:ok, _} = Persistence.create_account("testaccountB", "098f6bcd4621d373cade4e832627b4f6")

    :ok =
      test1235(account_id, %{kq_x: 6502, kq_y: 10_199, kq_date: ~U[2026-11-15 09:44:23Z]}, [{10, 1250}])

    test2(account_id, %{level: 8, kq_x: 6652, kq_y: 8601, kq_date: ~U[2026-11-15 11:06:59Z]})
  end

  @doc """
  Setup of `re-data/captures/26_11_16_37b_char-select-rename-refusals.md`. The account `admin` and the characters
  `Test1235`, `Test2` and `X37-Ren` (created as `X37Del` in capture 37 and renamed by the capture's prep). The rename
  right of `Test2` is not set up: character rename is milestone 2.
  """
  @spec char_select_rename_refusals() :: :ok
  def char_select_rename_refusals do
    account_id = accounts()

    :ok =
      test1235(account_id, %{kq_x: 5771, kq_y: 8796, kq_date: ~U[2026-11-16 10:21:06Z]}, [{10, 1250}])

    :ok = test2(account_id, %{level: 33, kq_x: 5758, kq_y: 8789, kq_date: ~U[2026-11-15 18:51:23Z]})

    _ =
      Factory.character(account_id, %{
        id: 7,
        slot: 2,
        name: "X37-Ren",
        race: 1,
        class: 21,
        gender: 1,
        hair: 4,
        tutorial_state: 0,
        kq_date: ~U[2026-11-15 16:08:48Z]
      })

    :ok
  end

  @doc """
  Setup of `re-data/captures/26_11_15_idle_in_world.md`. The account `admin` and the character `Test1235` with the
  stored values the capture's 0x1038 shows (experience, position, HP, SP, money, stones).
  """
  @spec idle_in_world() :: :ok
  def idle_in_world do
    accounts()
    |> test1235(%{
      kq_x: 6477,
      kq_y: 9844,
      kq_date: ~U[2026-11-13 11:57:15Z],
      exp: 10,
      login_x: 6477,
      login_y: 9844,
      hp: 3043,
      sp: 2851,
      money: 99_999_634_524,
      hp_stones: 386,
      sp_stones: 364
    })
  end

  defp test2(account_id, attrs) do
    character =
      Factory.character(
        account_id,
        Map.merge(
          %{id: 5, slot: 1, name: "Test2", race: 1, class: 6, hair: 2, hair_color: 1, face: 4, kq_map: "RouN"},
          attrs
        )
      )

    _ = Factory.item(character.id, 12, 751)
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
