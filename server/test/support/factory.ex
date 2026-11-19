defmodule Factory do
  @moduledoc "Test-only inserts of characters and equipped items (they have no public `Persistence` operation yet)."

  alias Persistence.Character
  alias Persistence.Item

  @defaults %{
    world_id: 0,
    slot: 0,
    name: "Char",
    level: 1,
    login_map: "RouN",
    race: 0,
    class: 1,
    gender: 0,
    hair: 0,
    hair_color: 0,
    face: 0,
    kq_map: "",
    kq_x: 0,
    kq_y: 0,
    kq_date: ~U[2026-01-01 00:00:00Z],
    tutorial_state: 2,
    tutorial_step: 0
  }

  @doc "Inserts a character of the account; `attrs` override the defaults (`id` is allowed)."
  @spec character(pos_integer(), map()) :: Character.t()
  def character(account_id, attrs \\ %{}) do
    attrs = Map.merge(@defaults, attrs)
    attrs = Map.put_new(attrs, :name_key, String.downcase(attrs.name, :ascii))
    repo = Persistence.Repo.active()
    character = repo.insert!(struct!(Character, Map.put(attrs, :account_id, account_id)))

    # PostgreSQL does not advance the id sequence for an explicit id: a later real insert would collide.
    if repo.__adapter__() == Ecto.Adapters.Postgres do
      repo.query!("SELECT setval(pg_get_serial_sequence('characters', 'id'), (SELECT max(id) FROM characters))")
    end

    character
  end

  @doc "Inserts an equipped item (storage 8) of a character."
  @spec item(pos_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: Item.t()
  def item(character_id, slot, item_id, upgrade \\ 0) do
    Persistence.Repo.active().insert!(%Item{
      character_id: character_id,
      storage: 8,
      slot: slot,
      item_id: item_id,
      upgrade: upgrade
    })
  end
end
