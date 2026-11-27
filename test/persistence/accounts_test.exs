defmodule Persistence.AccountsTest do
  # Tests of the inside of the boundary: they may call `Persistence.Repo.active/0`.
  use ExUnit.Case, async: false

  setup do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    :ok
  end

  defp create!(name, password \\ "pw") do
    {:ok, id} = Persistence.create_account(name, password)
    id
  end

  describe "create_account/2" do
    test "returns distinct positive user numbers" do
      a = create!("alice")
      b = create!("bob")
      assert a > 0 and b > 0 and a != b
    end

    test "name_taken for the same name and for another case" do
      create!("bob")
      assert {:error, :name_taken} = Persistence.create_account("bob", "x")
      assert {:error, :name_taken} = Persistence.create_account("Bob", "x")
    end

    test "invalid_name" do
      for name <- ["", "a b", "a" <> <<0xFF>>, String.duplicate("a", 256)] do
        assert {:error, :invalid_name} = Persistence.create_account(name, "x")
      end
    end

    test "a 255-byte name is accepted" do
      assert {:ok, _} = Persistence.create_account(String.duplicate("a", 255), "x")
    end
  end

  describe "a failing database" do
    @secret "5ebe2294ecd0e0f08eab7690d2a6ee69"

    test "check_login and create_account return :database and log without the password" do
      repo = Persistence.Repo.active()
      repo.query!("ALTER TABLE accounts RENAME TO accounts_off")
      on_exit(fn -> repo.query!("ALTER TABLE accounts_off RENAME TO accounts") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :database} = Persistence.check_login("ivy", @secret)
          assert {:error, :database} = Persistence.create_account("ivy", @secret)
        end)

      assert log =~ "the database failed in check_login"
      assert log =~ "the database failed in create_account"
      refute log =~ @secret
    end
  end

  describe "check_login/2" do
    test "ok, in another case and with trailing spaces" do
      id = create!("Dave")
      assert {:ok, ^id} = Persistence.check_login("Dave", "pw")
      assert {:ok, ^id} = Persistence.check_login("dAVE", "pw")
      assert {:ok, ^id} = Persistence.check_login("dave   ", "pw")
    end

    test "unknown" do
      assert {:error, :unknown} = Persistence.check_login("nobody", "pw")
      assert {:error, :unknown} = Persistence.check_login(<<0xFF>>, "pw")
    end

    test "wrong_password, also in another case and on a blocked account" do
      create!("erin", "Secret")
      assert {:error, :wrong_password} = Persistence.check_login("erin", "secret")
      assert {:error, :wrong_password} = Persistence.check_login("erin", "")
      :ok = Persistence.set_blocked("erin", true)
      assert {:error, :wrong_password} = Persistence.check_login("erin", "nope")
    end

    test "blocked, not_login_able and both" do
      create!("fay")
      :ok = Persistence.set_login_able("fay", false)
      assert {:error, :not_login_able} = Persistence.check_login("fay", "pw")
      :ok = Persistence.set_blocked("fay", true)
      assert {:error, :blocked} = Persistence.check_login("fay", "pw")
    end

    test "a password of arbitrary bytes round-trips" do
      id = create!("gus", <<0xFF, 0, 0x41>>)
      assert {:ok, ^id} = Persistence.check_login("gus", <<0xFF, 0, 0x41>>)
    end
  end

  describe "set_blocked/2 and set_login_able/2" do
    test "the effect shows in check_login and can be undone" do
      id = create!("hal")
      :ok = Persistence.set_blocked("hal", true)
      assert {:error, :blocked} = Persistence.check_login("hal", "pw")
      :ok = Persistence.set_blocked("hal", false)
      assert {:ok, ^id} = Persistence.check_login("hal", "pw")
      :ok = Persistence.set_login_able("hal", false)
      assert {:error, :not_login_able} = Persistence.check_login("hal", "pw")
      :ok = Persistence.set_login_able("HAL", true)
      assert {:ok, ^id} = Persistence.check_login("hal", "pw")
    end

    test "unknown for a missing name" do
      assert {:error, :unknown} = Persistence.set_blocked("nobody", true)
      assert {:error, :unknown} = Persistence.set_login_able("nobody", true)
    end
  end

  test "the same password gives different hashes and salts" do
    create!("ida", "same")
    create!("jan", "same")

    %{rows: [[h1, s1, i1], [h2, s2, i2]]} =
      Persistence.Repo.active().query!("SELECT password_hash, password_salt, password_iterations FROM accounts")

    assert h1 != h2 and s1 != s2
    assert byte_size(h1) == 32 and h1 != "same"
    assert i1 == 1_000 and i2 == 1_000
  end
end
