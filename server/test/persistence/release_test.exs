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
end
