defmodule Zone.Npc do
  @moduledoc """
  A standing NPC placed on a map instance from a `ShineNPC` row, with its handle and its prebuilt appear element
  (`0x1C08`, also the element of `0x1C09`). `brief` is `:none` when no `MobInfo` row has the NPC's mob name: such
  an NPC keeps its handle and is shown to nobody.

  The element (all NPC elements of the captures): mode 2, the mob id of the `MobInfo` row, the coordinates of the
  row, the direction `Direct / 2` truncated towards zero, plus 180 when negative. A gate (`Gate`, `IDGate`,
  `ModeIDGate`, `RandomGate` with a `LinkTable` row for its argument) has flag state 1 and the client map of the
  first such row in its flag, with byte 36 of the flag set to 0x08 (`NPCRole_Portal::nrb_BriefInformSet` @
  FUN_004c2360, `so_SetGateBriefInform` @ FUN_00557bc0; the byte is captured in all gate elements).
  """

  alias Proto.Packets.BriefinfoRegenmobCmd

  @gate_roles ["Gate", "IDGate", "ModeIDGate", "RandomGate"]

  @enforce_keys [:handle, :row, :x, :y, :brief]
  defstruct @enforce_keys ++ [dimension: 0, sub_layer: 0]

  @type t :: %__MODULE__{
          handle: non_neg_integer(),
          row: GameData.ShineNpc.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          brief: BriefinfoRegenmobCmd.t() | :none,
          dimension: integer(),
          sub_layer: 0..5
        }

  @doc "The NPC of a `ShineNPC` row with its handle."
  @spec new(GameData.ShineNpc.t(), non_neg_integer()) :: t()
  def new(%GameData.ShineNpc{} = row, handle) do
    %__MODULE__{handle: handle, row: row, x: row.x, y: row.y, brief: brief(row, handle)}
  end

  defp brief(row, handle) do
    case GameData.lookup(GameData.MobInfo, :inx_name, row.mob_name) do
      [mob | _] ->
        {flagstate, flag} = flag(row)

        %BriefinfoRegenmobCmd{
          handle: handle,
          mode: 2,
          mob_id: mob.id,
          x: row.x,
          y: row.y,
          dir: dir(row.direct),
          flagstate: flagstate,
          flag: flag,
          animation: "",
          animation_level: 0,
          kq_team_type: 2,
          regen_ani: 0
        }

      [] ->
        :none
    end
  end

  defp dir(direct) do
    half = div(direct, 2)
    if half < 0, do: half + 180, else: half
  end

  defp flag(%{role: role, role_arg: arg}) when role in @gate_roles do
    case GameData.lookup(GameData.LinkTable, :argument, arg) do
      [link | _] -> {1, pad(link.map_client) <> <<0::192, 0x08, 0::496>>}
      [] -> {0, <<0::792>>}
    end
  end

  defp flag(_row), do: {0, <<0::792>>}

  # the client map name is at most 12 bytes (char[12] of gate2where)
  defp pad(name), do: binary_part(name <> <<0::96>>, 0, 12)
end
