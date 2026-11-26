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

  @doc """
  Setup of `re-data/captures/26_11_15_walk-run-portals.md`. The account `admin` and the character `Test1235` with the
  stored values the capture's 0x0C14 and 0x1038 show (Kingdom Quest place and date, experience, position, HP, SP,
  money, stones) and the one equipped item of its 0x1047 and 0x1C05 (1250).
  """
  @spec walk_run_portals() :: :ok
  def walk_run_portals do
    accounts()
    |> test1235(
      %{
        kq_x: 5926,
        kq_y: 8346,
        kq_date: ~U[2026-11-15 09:14:46Z],
        exp: 10,
        login_x: 5926,
        login_y: 8346,
        hp: 3033,
        sp: 2841,
        money: 99_999_634_524,
        hp_stones: 386,
        sp_stones: 364
      },
      [{10, 1250}]
    )
  end

  @doc """
  Setup of `re-data/captures/26_11_16_38_session-loss-kicks-char-select.md`. The account `admin` and the three
  characters its first 0x0C14 lists; `Test1235` with the stored values its first 0x1038 shows.
  """
  @spec session_loss_kicks_char_select() :: :ok
  def session_loss_kicks_char_select do
    account_id = accounts()

    :ok =
      test1235(
        account_id,
        %{
          kq_x: 5763,
          kq_y: 8762,
          kq_date: ~U[2026-11-15 19:00:42Z],
          exp: 13,
          login_x: 5763,
          login_y: 8762,
          hp: 3033,
          sp: 2794,
          money: 99_999_634_524,
          hp_stones: 386,
          sp_stones: 364
        },
        [{10, 1250}]
      )

    :ok = test2(account_id, %{level: 33, kq_x: 5758, kq_y: 8789, kq_date: ~U[2026-11-15 18:51:23Z]})

    _ =
      Factory.character(account_id, %{
        id: 7,
        slot: 2,
        name: "X37Del",
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
  Setup of `re-data/captures/26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort.md`. The account `admin` with
  the four characters its 0x0C14 lists (`X45A` in slot 3) and the account `testaccountB` with its two (`X45B` in
  slot 1); `X45A` and `X45B` with the stored values their 0x1038 shows (level, experience, position, HP, SP, stones).
  """
  @spec walk_sit_emote() :: :ok
  def walk_sit_emote do
    account_id = accounts()

    :ok =
      test1235(account_id, %{kq_x: 5756, kq_y: 8745, kq_date: ~U[2026-11-16 10:54:42Z]}, [{10, 1250}])

    :ok = test2(account_id, %{level: 33, kq_x: 5758, kq_y: 8789, kq_date: ~U[2026-11-16 10:53:06Z]})

    x37 =
      Factory.character(account_id, %{
        id: 7,
        slot: 2,
        name: "X37Del",
        level: 2,
        race: 1,
        class: 21,
        gender: 1,
        hair: 4,
        kq_map: "RouN",
        kq_x: 6596,
        kq_y: 6931,
        kq_date: ~U[2026-11-21 11:56:58Z]
      })

    _ = Factory.item(x37.id, 12, 57_363)

    _ =
      Factory.character(account_id, %{
        id: 15,
        slot: 3,
        name: "X45A",
        level: 40,
        race: 1,
        class: 21,
        gender: 1,
        hair: 4,
        exp: 1_389_279,
        login_x: 6397,
        login_y: 9849,
        hp: 48,
        sp: 46,
        hp_stones: 15,
        sp_stones: 11,
        kq_map: "RouN",
        kq_x: 6397,
        kq_y: 9849,
        kq_date: ~U[2026-11-21 17:23:57Z]
      })

    {:ok, b_id} = Persistence.create_account("testaccountB", "098f6bcd4621d373cade4e832627b4f6")

    x14 =
      Factory.character(b_id, %{
        id: 8,
        slot: 0,
        name: "X14B",
        race: 3,
        class: 16,
        hair: 1,
        hair_color: 1,
        face: 4,
        kq_map: "RouN",
        kq_x: 6431,
        kq_y: 8801,
        kq_date: ~U[2026-11-15 17:44:03Z]
      })

    _ = Factory.item(x14.id, 12, 1750)

    _ =
      Factory.character(b_id, %{
        id: 16,
        slot: 1,
        name: "X45B",
        level: 40,
        race: 2,
        class: 14,
        exp: 1_389_279,
        login_x: 6843,
        login_y: 9850,
        hp: 46,
        sp: 24,
        hp_stones: 13,
        sp_stones: 10,
        kq_date: ~U[2026-11-21 17:22:02Z]
      })

    :ok
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
    :ok = TestSessions.wait_none()
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
