defmodule WorldManager.CharacterCreate do
  @moduledoc """
  Character creation of `0x1401` (W01 §4.1, D02 §3.3; flow: `docs/technical/flows/character-create.md`).

  The checks run in the order of the original, the first failure wins. The codes are the decided ones: W01-B2 and
  D02-B1 fixed (accurate codes instead of `0x84` / `0x182` / `0x183`), W01-B4 kept (a name has up to 20 bytes).
  """

  alias Proto.Packets.AvatarCreateReq

  @type refusal :: :slot | :name | :class | :name_taken | :failed

  @max_slot 6

  @spec run(non_neg_integer(), pos_integer(), AvatarCreateReq.t()) ::
          {:ok, Persistence.character()} | {:error, refusal()}
  def run(world_id, user_no, %AvatarCreateReq{} = req) do
    with :ok <- check(req.slot < @max_slot, :slot),
         :ok <- check(valid_name?(req.name), :name),
         :ok <- sentinel_allowed(world_id, user_no, req.chrclass),
         :ok <- look_allowed(req),
         {:ok, default} <- fetch(GameData.CharDefault, req.chrclass, :class),
         {:ok, items} <- items(req.chrclass) do
      attrs = %{
        world_id: world_id,
        account_id: user_no,
        slot: req.slot,
        name: req.name,
        level: default.init_level,
        exp: default.init_exp,
        login_map: default.start_map,
        login_x: default.start_x,
        login_y: default.start_y,
        hp: default.hp,
        sp: default.sp,
        hp_stones: default.hp_stones,
        sp_stones: default.sp_stones,
        money: default.money,
        race: race(req.chrclass),
        class: req.chrclass,
        gender: req.gender,
        hair: req.hairtype,
        hair_color: req.haircolor,
        face: req.faceshape,
        tutorial_state: if(req.chrclass == 26, do: 2, else: 0),
        items: items,
        skills:
          GameData.CharDefaultSkill |> GameData.lookup(:class, req.chrclass) |> Enum.map(& &1.skill_id) |> Enum.uniq(),
        shortcuts: shortcuts(req.chrclass)
      }

      case Persistence.create_character(attrs) do
        {:ok, character} -> {:ok, character}
        {:error, :slot_in_use} -> {:error, :slot}
        {:error, :name_taken} -> {:error, :name_taken}
        {:error, :database} -> {:error, :failed}
      end
    end
  end

  @doc "The client error code of a refusal (client texts: `0x85` max slot, `0x82` failed, `0x83` wrong class, `0x181` name in use)."
  @spec code(refusal()) :: 0..0xFFFF
  def code(:slot), do: 0x85
  def code(:name), do: 0x82
  def code(:class), do: 0x83
  def code(:name_taken), do: 0x181
  def code(:failed), do: 0x82

  @doc "1 to 20 bytes, no space, not in `BadNameFilter.shn` (`Type 0`: equal; `Type 1`: contained)."
  @spec valid_name?(binary()) :: boolean()
  def valid_name?(name) do
    byte_size(name) in 1..20 and not String.contains?(name, " ") and not bad?(upcase(name))
  end

  defp bad?(upper) do
    Enum.any?(GameData.lookup(GameData.BadNameFilter, :type, 0), &(upcase(&1.bad_name) == upper)) or
      Enum.any?(GameData.lookup(GameData.BadNameFilter, :type, 1), fn row ->
        # As in the original, the row is not upper-cased: a row with a lower-case letter never matches.
        row.bad_name != "" and :binary.match(upper, row.bad_name) != :nomatch
      end)
  end

  defp upcase(bin), do: for(<<b <- bin>>, into: <<>>, do: <<if(b in ?a..?z, do: b - 32, else: b)>>)

  defp check(true, _refusal), do: :ok
  defp check(false, refusal), do: {:error, refusal}

  defp fetch(schema, key, refusal) do
    case GameData.fetch(schema, key) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, refusal}
    end
  end

  defp sentinel_allowed(world_id, user_no, 26) do
    required =
      case GameData.fetch(GameData.SingleData, "ChrLevel_CanCreateSen") do
        {:ok, row} -> row.value
        :error -> 0
      end

    case Persistence.list_characters(world_id, user_no) do
      {:ok, characters} ->
        highest = characters |> Enum.map(& &1.level) |> Enum.max(fn -> 0 end)
        check(highest >= required, :class)

      {:error, :database} ->
        {:error, :failed}
    end
  end

  defp sentinel_allowed(_world_id, _user_no, _class), do: :ok

  defp look_allowed(req) do
    ok? =
      Enum.all?(
        [
          {GameData.HairInfo, req.hairtype},
          {GameData.HairColorInfo, req.haircolor},
          {GameData.FaceInfo, req.faceshape}
        ],
        fn {schema, id} -> match?({:ok, %{grade: 0}}, GameData.fetch(schema, id)) end
      )

    check(ok?, :failed)
  end

  # The first weapon (ItemInfo class 5) is equipped, everything else goes to the inventory in file order.
  defp items(class) do
    rows = GameData.lookup(GameData.CharDefaultItem, :class, class)

    rows
    |> Enum.reduce_while({:ok, [], 0, false}, fn row, {:ok, acc, next, equipped?} ->
      case GameData.follow(row, :item_id) do
        {:ok, %{class: 5, equip: equip}} when not equipped? and equip in [10, 12] ->
          {:cont, {:ok, [%{storage: 8, slot: equip, item_id: row.item_id, lot: row.lot} | acc], next, true}}

        {:ok, %{class: 5}} when not equipped? ->
          {:halt, {:error, :failed}}

        {:ok, _info} ->
          {:cont, {:ok, [%{storage: 9, slot: next, item_id: row.item_id, lot: row.lot} | acc], next + 1, equipped?}}

        :error ->
          {:halt, {:error, :failed}}
      end
    end)
    |> case do
      {:ok, acc, _next, _equipped?} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  defp shortcuts(class) do
    GameData.CharDefaultShortcut
    |> GameData.lookup(:class, class)
    |> Map.new(&{&1.slot_no, %{slot: &1.slot_no, code: &1.code_no, value: &1.value}})
    |> Map.values()
  end

  # g_ClassRace of the original; the race bits of the request are ignored.
  defp race(class) when class in 1..10 or class in 21..25, do: 1
  defp race(class) when class in 11..15 or class in 26..27, do: 2
  defp race(class) when class in 16..20, do: 3
  defp race(_class), do: 0
end
