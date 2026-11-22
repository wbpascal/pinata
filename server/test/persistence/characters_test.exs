defmodule Persistence.CharactersTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import Ecto.Query

  @keys ~w(id slot name level login_map race class gender hair hair_color face kq_map kq_x kq_y kq_date tutorial_state tutorial_step equipment)a

  setup do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, id} = Persistence.create_account("admin", "pw")
    %{id: id}
  end

  test "lists in slot order with equipment, without other storages or other accounts", %{id: id} do
    {:ok, other} = Persistence.create_account("other", "pw")
    b = Factory.character(id, %{slot: 2, name: "B"})
    a = Factory.character(id, %{slot: 1, name: "A"})
    Factory.character(other, %{slot: 0, name: "C"})
    Factory.character(id, %{slot: 0, name: "W", world_id: 1})
    Factory.item(a.id, 12, 5, 2)
    Factory.item(a.id, 3, 4)

    Persistence.Repo.active().query!(
      "INSERT INTO items (character_id, storage, slot, item_id, upgrade) VALUES (#{a.id}, 1, 5, 9, 0)"
    )

    Factory.item(b.id, 1, 7)

    assert {:ok, [first, second]} = Persistence.list_characters(0, id)
    assert Enum.sort(Map.keys(first)) == Enum.sort(@keys)
    assert [first.name, second.name] == ["A", "B"]
    assert first.equipment == [%{slot: 3, item_id: 4, upgrade: 0}, %{slot: 12, item_id: 5, upgrade: 2}]
    assert second.equipment == [%{slot: 1, item_id: 7, upgrade: 0}]
    assert {:ok, []} = Persistence.list_characters(0, id + 100)
  end

  test "a database failure is an error value" do
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)
    assert {:error, :database} = Persistence.list_characters(0, 1)
  end

  test "a name that is not UTF-8 is stored unchanged", %{id: id} do
    name = <<0xC7>> <> String.duplicate("a", 19)
    Factory.character(id, %{name: name})
    assert {:ok, [%{name: ^name}]} = Persistence.list_characters(0, id)
  end

  describe "constraints" do
    test "each bad row is refused", %{id: id} do
      Factory.character(id, %{slot: 1, name: "Taken"})

      bad = [
        %{slot: 6},
        %{name: String.duplicate("a", 21)},
        %{name: ""},
        %{level: 0},
        %{level: 256},
        %{slot: 1, name: "Free"},
        %{slot: 2, name: "TAKEN"},
        %{id: 4_294_967_296}
      ]

      for attrs <- bad do
        attrs = Map.put_new(attrs, :name, "Name#{map_size(attrs)}#{attrs[:level]}")
        assert catch_error(Factory.character(id, attrs)), inspect(attrs)
      end

      # the same name in another world is allowed
      Factory.character(id, %{slot: 2, name: "TAKEN", world_id: 1})
    end

    test "an item with item_id 65536 is refused", %{id: id} do
      c = Factory.character(id)
      assert catch_error(Factory.item(c.id, 1, 65_536))
    end
  end

  describe "create_character/1" do
    alias Persistence.Item
    alias Persistence.Shortcut
    alias Persistence.Skill

    defp attrs(id, overrides \\ %{}) do
      Map.merge(
        %{
          world_id: 0,
          account_id: id,
          slot: 0,
          name: "New",
          level: 1,
          exp: 123_456_789_012,
          login_map: "RouN",
          login_x: 6888,
          login_y: 7045,
          hp: 100,
          sp: 50,
          hp_stones: 3,
          sp_stones: 4,
          money: 5_000_000_000,
          race: 1,
          class: 1,
          gender: 0,
          hair: 1,
          hair_color: 2,
          face: 3,
          tutorial_state: 0,
          items: [%{storage: 9, slot: 0, item_id: 46_003, lot: 7}, %{storage: 8, slot: 12, item_id: 62_923, lot: 1}],
          skills: [29_200, 29_201],
          shortcuts: [%{slot: 1, code: 2, value: 3}]
        },
        overrides
      )
    end

    defp count(schema), do: Persistence.Repo.active().aggregate(schema, :count)

    test "stores the character with its items, skills and shortcuts", %{id: id} do
      Application.put_env(:pinata, :clock_source, TestClock)
      TestClock.set(1_794_733_600_925_868)
      on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)

      assert {:ok, c} = Persistence.create_character(attrs(id))
      assert {:ok, [^c]} = Persistence.list_characters(0, id)
      assert c.equipment == [%{slot: 12, item_id: 62_923, upgrade: 0}]
      assert c.kq_date == ~U[2026-11-15 09:06:40Z]
      assert {count(Item), count(Skill), count(Shortcut)} == {2, 2, 1}

      repo = Persistence.Repo.active()

      assert repo.one(from(c in Persistence.Character, select: {c.exp, c.login_x, c.money})) ==
               {123_456_789_012, 6888, 5_000_000_000}

      assert repo.one(from(i in Item, where: i.storage == 9, select: i.lot)) == 7
    end

    test "slot in use wins over name taken, a name is unique per world", %{id: id} do
      {:ok, other} = Persistence.create_account("other", "pw")
      assert {:ok, _} = Persistence.create_character(attrs(id))
      assert {:error, :slot_in_use} = Persistence.create_character(attrs(id, %{name: "Else"}))
      assert {:error, :slot_in_use} = Persistence.create_character(attrs(id))
      assert {:error, :name_taken} = Persistence.create_character(attrs(id, %{slot: 1, name: "NEW"}))
      assert {:error, :name_taken} = Persistence.create_character(attrs(other, %{name: "nEw"}))
      assert {:ok, _} = Persistence.create_character(attrs(id, %{slot: 1, world_id: 1}))
    end

    test "after :name_taken the repo is not in a transaction and nothing was written (D02-B2)", %{id: id} do
      assert {:ok, _} = Persistence.create_character(attrs(id))
      before = {count(Item), count(Skill), count(Shortcut)}
      assert {:error, :name_taken} = Persistence.create_character(attrs(id, %{slot: 1}))
      refute Persistence.Repo.active().in_transaction?()
      assert {count(Item), count(Skill), count(Shortcut)} == before
      assert {:ok, _} = Persistence.create_character(attrs(id, %{slot: 1, name: "Free"}))
    end

    test "a database failure is an error value", %{id: id} do
      Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
      on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)
      assert {:error, :database} = Persistence.create_character(attrs(id))
    end

    test "a name that is not UTF-8 is created and listed unchanged", %{id: id} do
      name = <<0xC7>> <> String.duplicate("a", 19)
      assert {:ok, _} = Persistence.create_character(attrs(id, %{name: name}))
      assert {:ok, [%{name: ^name}]} = Persistence.list_characters(0, id)
    end
  end

  describe "delete_character/3" do
    alias Persistence.Item
    alias Persistence.Shortcut
    alias Persistence.Skill

    test "deletes the character with everything it owns", %{id: id} do
      {:ok, _} = Persistence.create_character(attrs(id))
      {:ok, _} = Persistence.create_character(attrs(id, %{slot: 1, name: "Keep"}))
      assert {count(Item), count(Skill), count(Shortcut)} == {4, 4, 2}

      assert :ok = Persistence.delete_character(0, id, 0)
      assert {:ok, [%{name: "Keep"}]} = Persistence.list_characters(0, id)
      assert {count(Item), count(Skill), count(Shortcut)} == {2, 2, 1}
      refute Persistence.Repo.active().in_transaction?()
    end

    test "an empty slot, a slot out of range, another account and another world are not found", %{id: id} do
      {:ok, other} = Persistence.create_account("other", "pw")
      {:ok, _} = Persistence.create_character(attrs(id))

      for {world, account, slot} <- [{0, id, 1}, {0, id, 6}, {0, id, 255}, {0, other, 0}, {1, id, 0}] do
        assert {:error, :not_found} = Persistence.delete_character(world, account, slot)
      end

      assert {:ok, [%{name: "New"}]} = Persistence.list_characters(0, id)
    end

    test "the slot and the name are free at once", %{id: id} do
      {:ok, first} = Persistence.create_character(attrs(id))
      assert :ok = Persistence.delete_character(0, id, 0)
      assert {:ok, second} = Persistence.create_character(attrs(id))
      assert second.id > first.id
    end

    test "a database failure is an error value", %{id: id} do
      Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
      on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)
      assert {:error, :database} = Persistence.delete_character(0, id, 0)
    end
  end

  describe "skip_tutorial/3" do
    test "sets tutorial state 0 to 2", %{id: id} do
      Factory.character(id, %{slot: 1, name: "Tut", tutorial_state: 0})
      assert :ok = Persistence.skip_tutorial(0, id, 1)
      assert {:ok, [%{tutorial_state: 2}]} = Persistence.list_characters(0, id)
      refute Persistence.Repo.active().in_transaction?()
    end

    test "a state other than 0 and an empty slot are not found", %{id: id} do
      Factory.character(id, %{slot: 0, name: "Done", tutorial_state: 1})
      assert {:error, :not_found} = Persistence.skip_tutorial(0, id, 0)
      assert {:error, :not_found} = Persistence.skip_tutorial(0, id, 2)
      assert {:ok, [%{tutorial_state: 1}]} = Persistence.list_characters(0, id)
    end

    test "a database failure is an error value", %{id: id} do
      Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
      on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)
      assert {:error, :database} = Persistence.skip_tutorial(0, id, 0)
    end
  end

  describe "rename_character/4" do
    test "renames, and the list shows the new name", %{id: id} do
      {:ok, _} = Persistence.create_character(attrs(id))
      assert :ok = Persistence.rename_character(0, id, 0, "Newer")
      assert {:ok, [%{name: "Newer"}]} = Persistence.list_characters(0, id)
    end

    test "an empty slot and another account's slot are not found", %{id: id} do
      {:ok, other} = Persistence.create_account("other", "pw")
      {:ok, _} = Persistence.create_character(attrs(id))
      assert {:error, :not_found} = Persistence.rename_character(0, id, 1, "Free")
      assert {:error, :not_found} = Persistence.rename_character(0, other, 0, "Free")
    end

    test "a name of another character in another letter case is taken, and nothing changes", %{id: id} do
      {:ok, _} = Persistence.create_character(attrs(id))
      {:ok, _} = Persistence.create_character(attrs(id, %{slot: 1, name: "Keep"}))
      assert {:error, :name_taken} = Persistence.rename_character(0, id, 0, "KEEP")
      assert {:ok, [%{name: "New"}, %{name: "Keep"}]} = Persistence.list_characters(0, id)
      assert :ok = Persistence.rename_character(0, id, 0, "Free")
      refute Persistence.Repo.active().in_transaction?()
    end
  end
end
