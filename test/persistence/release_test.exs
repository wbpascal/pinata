defmodule Persistence.ReleaseTest do
  # Tests of the inside of the boundary: they may call `Persistence.Repo.active/0`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    :ok
  end

  test "create_account stores the MD5 of the typed password" do
    out = capture_io("secret\n", fn -> Persistence.Release.create_account("carol") end)
    assert out =~ "user number"
    assert {:ok, _} = Persistence.check_login("carol", "5ebe2294ecd0e0f08eab7690d2a6ee69")
  end

  test "create_account fails on empty input and on a taken name" do
    assert_raise RuntimeError, ~r/No password/, fn ->
      capture_io("\n", fn -> Persistence.Release.create_account("dan") end)
    end

    capture_io("x\n", fn -> Persistence.Release.create_account("dan") end)

    assert_raise RuntimeError, ~r/exists/, fn ->
      capture_io("x\n", fn -> Persistence.Release.create_account("dan") end)
    end
  end

  test "block and unblock" do
    capture_io("x\n", fn -> Persistence.Release.create_account("eve") end)
    capture_io(fn -> :ok = Persistence.Release.block("eve") end)
    assert {:error, :blocked} = Persistence.check_login("eve", Base.encode16(:crypto.hash(:md5, "x"), case: :lower))
    capture_io(fn -> :ok = Persistence.Release.unblock("eve") end)
    assert {:ok, _} = Persistence.check_login("eve", Base.encode16(:crypto.hash(:md5, "x"), case: :lower))

    assert_raise RuntimeError, ~r/No account/, fn -> capture_io(fn -> Persistence.Release.block("nobody") end) end
  end

  test "migrate with nothing pending" do
    capture_io(fn -> assert :ok = Persistence.Release.migrate() end)
  end

  test "create_accounts creates a numbered batch and counts existing names" do
    out = capture_io("secret\n", fn -> :ok = Persistence.Release.create_accounts("load", 3) end)
    assert out =~ "Created 3 accounts, 0 existed already: load0001 to load0003."
    assert {:ok, _} = Persistence.check_login("load0002", "5ebe2294ecd0e0f08eab7690d2a6ee69")

    out = capture_io("secret\n", fn -> :ok = Persistence.Release.create_accounts("load", 3) end)
    assert out =~ "Created 0 accounts, 3 existed already"
  end

  test "create_accounts refuses a bad count and an invalid prefix" do
    for count <- [0, 10_000] do
      assert_raise RuntimeError, "The count must be 1 to 9999.", fn ->
        capture_io("x\n", fn -> Persistence.Release.create_accounts("load", count) end)
      end
    end

    assert_raise RuntimeError, ~r/not a valid account name/, fn ->
      capture_io("x\n", fn -> Persistence.Release.create_accounts("lo ad", 1) end)
    end
  end

  describe "place_characters" do
    setup do
      {:ok, id} = Persistence.create_account("placer", "pw")
      %{character: Factory.character(id, %{name: "Name"})}
    end

    test "places the characters of the lines", %{character: c} do
      out = capture_io("Name,RouN,100,200\r\n\n", fn -> :ok = Persistence.Release.place_characters() end)
      assert out =~ "Placed 1 characters."
      row = Persistence.Repo.active().get!(Persistence.Character, c.id)
      assert {row.login_map, row.login_x, row.login_y} == {"RouN", 100, 200}
    end

    test "refuses empty input, a malformed line and an unknown name" do
      assert_raise RuntimeError, "No placement lines given.", fn ->
        capture_io("", fn -> Persistence.Release.place_characters() end)
      end

      for line <- ["Name,RouN,100", "Name,Ro uN,1,2", "Name,RouN,-1,2", "Name,RouN,1,2x", ",RouN,1,2"] do
        assert_raise RuntimeError, "Line 2 is not <character name>,<map>,<x>,<y>: #{inspect(line)}", fn ->
          capture_io("Name,RouN,1,2\n" <> line, fn -> Persistence.Release.place_characters() end)
        end
      end

      assert_raise RuntimeError, "No character named Ghost in world 0; nothing was placed.", fn ->
        capture_io("Ghost,RouN,1,2\n", fn -> Persistence.Release.place_characters() end)
      end
    end
  end

  describe "set_admin_level" do
    setup do
      {:ok, id} = Persistence.create_account("gm", "pw")
      %{account: id, character: Factory.character(id, %{name: "Boss"})}
    end

    defp level_of(id), do: Persistence.Repo.active().get!(Persistence.Character, id).admin_level

    test "sets the level, names without letter case, and says only the database changed", %{character: c} do
      out = capture_io(fn -> :ok = Persistence.Release.set_admin_level("boss", 100) end)
      assert out =~ "Admin level of boss in world 0 set to 100."
      assert out =~ "Only the database was changed: a character in the world keeps its old level until its next login."
      assert level_of(c.id) == 100

      capture_io(fn -> :ok = Persistence.Release.set_admin_level("Boss", 0, 0) end)
      assert level_of(c.id) == 0
    end

    test "refuses a level out of range and an unknown character", %{character: c} do
      for level <- [256, -1] do
        assert_raise RuntimeError, "The level must be 0 to 255.", fn ->
          capture_io(fn -> Persistence.Release.set_admin_level("Boss", level) end)
        end
      end

      assert_raise RuntimeError, "No character named Ghost in world 0.", fn ->
        capture_io(fn -> Persistence.Release.set_admin_level("Ghost", 10) end)
      end

      assert_raise RuntimeError, "World 7 is not configured.", fn ->
        capture_io(fn -> Persistence.Release.set_admin_level("Boss", 10, 7) end)
      end

      assert level_of(c.id) == 0
    end

    test "with two worlds the world must be named", %{account: account} do
      old = System.fetch_env!("PINATA_CONFIG")
      path = Path.join(System.tmp_dir!(), "pinata-two-worlds-#{System.unique_integer([:positive])}.toml")

      File.write!(
        path,
        File.read!(old) <>
          """

          [[world]]
          number = 0
          name = "One"

          [[world]]
          number = 1
          name = "Two"
          """
      )

      System.put_env("PINATA_CONFIG", path)

      on_exit(fn ->
        System.put_env("PINATA_CONFIG", old)
        File.rm(path)
      end)

      c = Factory.character(account, %{world_id: 1, name: "Other"})

      assert_raise RuntimeError, "More than one world is configured (0, 1): name the world with --world <n>.", fn ->
        capture_io(fn -> Persistence.Release.set_admin_level("Other", 10) end)
      end

      out = capture_io(fn -> :ok = Persistence.Release.set_admin_level("Other", 10, 1) end)
      assert out =~ "in world 1 set to 10"
      assert level_of(c.id) == 10

      assert_raise RuntimeError, "World 7 is not configured.", fn ->
        capture_io(fn -> Persistence.Release.set_admin_level("Other", 10, 7) end)
      end
    end
  end

  describe "mix pinata.character.admin_level" do
    test "refuses malformed arguments" do
      usage = "Usage: mix pinata.character.admin_level <character name> <level> [--world <n>]"

      for args <- [[], ["Boss"], ["Boss", "1x"], ["Boss", "1", "extra"], ["Boss", "1", "--world", "a"]] do
        assert_raise Mix.Error, usage, fn -> Mix.Tasks.Pinata.Character.AdminLevel.run(args) end
      end
    end
  end
end
