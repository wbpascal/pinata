defmodule Persistence.CharactersTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

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
end
