defmodule GameData.CharDefault do
  @moduledoc """
  Schema of the `CHARACTER` rows of `DefaultCharacterData.txt` (server data table). Read by character creation (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [
    :class,
    :start_map,
    :start_x,
    :start_y,
    :hp,
    :sp,
    :hp_stones,
    :sp_stones,
    :money,
    :init_level,
    :init_exp
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          class: integer(),
          start_map: binary(),
          start_x: integer(),
          start_y: integer(),
          hp: integer(),
          sp: integer(),
          hp_stones: integer(),
          sp_stones: integer(),
          money: integer(),
          init_level: integer(),
          init_exp: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/DefaultCharacterData/CHARACTER.csv"},
      key: :class,
      columns: [
        class: {"Class", :integer},
        start_map: {"StartMap", :string},
        start_x: {"StartX", :integer},
        start_y: {"StartY", :integer},
        hp: {"HP", :integer},
        sp: {"SP", :integer},
        hp_stones: {"HPStone", :integer},
        sp_stones: {"SPStone", :integer},
        money: {"Money", :integer},
        init_level: {"InitLV", :integer},
        init_exp: {"InitEXP", :integer}
      ],
      indexes: [],
      references: [start_map: GameData.MapInfo]
    }
  end
end
