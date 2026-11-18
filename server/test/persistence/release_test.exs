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
end
