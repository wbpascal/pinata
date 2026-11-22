defmodule Proto.Packets.BriefinfoInformCmd do
  @moduledoc "0x1C01 NC_BRIEFINFO_INFORM_CMD, client to server: the client asks for the appear packet of an object it does not know."
  use Proto.Packet, opcode: 0x1C01
  # official: nMyHnd
  field :my_handle, :u16
  # official: ReceiveNetCommand
  field :receive_net_command, :u16
  # official: hnd
  field :handle, :u16
end

defmodule Proto.Packets.BriefinfoLogincharacterCmd do
  @moduledoc """
  0x1C06 NC_BRIEFINFO_LOGINCHARACTER_CMD, server to client (235 bytes): the appear packet of a player; also the
  element of `0x1C07`.
  """
  use Proto.Packet, opcode: 0x1C06
  field :handle, :u16
  # official: charid
  field :name, {:char, 20}
  # official: coord.xy.x
  field :x, :u32
  # official: coord.xy.y
  field :y, :u32
  # official: coord.dir
  field :dir, :u8
  field :mode, :u8
  field :chrclass, :u8
  # official: shape
  bits gender: 1, shape_class: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
  # official: shapedata.notcamp.equip (Equ_Head to Equ_AccShield)
  field :equip, {:u16s, 20}
  # official: shapedata.notcamp.upgrade
  bits upgrade_righthand: 4, upgrade_lefthand: 4
  bits upgrade_leg: 4, upgrade_body: 4
  bits upgrade_unused: 4, upgrade_shoes: 4
  # the union is 45 bytes, PROTO_EQUIPMENT 43
  field :shapedata_rest, {:bytes, 2}
  field :polymorph, :u16
  # official: emoticon.emoticonid
  field :emoticon_id, :u8
  # official: emoticon.emoticonframe
  field :emoticon_frame, :u16
  # official: chartitle.Type
  field :title_type, :u8
  # official: chartitle.ElementNo
  field :title_element, :u8
  # official: chartitle.MobID
  field :title_mob_id, :u16
  field :abstatebit, {:bytes, 99}
  field :myguild, :u32
  field :type, :u8
  # official: isGuildAcademyMember
  field :is_guild_academy_member, :u8
  # official: IsAutoPick
  field :is_auto_pick, :u8
  # official: Level
  field :level, :u8
  # official: sAnimation
  field :animation, {:char, 32}
  # official: nMoverHnd
  field :mover_handle, :u16
  # official: nMoverSlot
  field :mover_slot, :u8
  # official: nKQTeamType
  field :kq_team_type, :u8
  # official: IsUseItemMinimon
  field :is_use_item_minimon, :u8
end

defmodule Proto.Packets.BriefinfoCharacterCmd do
  @moduledoc "0x1C07 NC_BRIEFINFO_CHARACTER_CMD, server to client: the players in sight, at most 28 per packet."
  use Proto.Packet, opcode: 0x1C07
  array :chars, Proto.Packets.BriefinfoLogincharacterCmd, count: :u8
end

defmodule Proto.Packets.BriefinfoRegenmobCmd do
  @moduledoc """
  0x1C08 NC_BRIEFINFO_REGENMOB_CMD, server to client (149 bytes): the appear packet of an NPC or a monster; also the
  element of `0x1C09`.
  """
  use Proto.Packet, opcode: 0x1C08
  field :handle, :u16
  field :mode, :u8
  # official: mobid
  field :mob_id, :u16
  # official: coord.xy.x
  field :x, :u32
  # official: coord.xy.y
  field :y, :u32
  # official: coord.dir
  field :dir, :u8
  field :flagstate, :u8
  # official: flag, the union of abstatebit and gate2where (char[12])
  field :flag, {:bytes, 99}
  # official: sAnimation
  field :animation, {:char, 32}
  # official: nAnimationLevel
  field :animation_level, :u8
  # official: nKQTeamType
  field :kq_team_type, :u8
  # official: bRegenAni
  field :regen_ani, :u8
end

defmodule Proto.Packets.BriefinfoMobCmd do
  @moduledoc "0x1C09 NC_BRIEFINFO_MOB_CMD, server to client: NPCs and monsters in sight, at most 28 per packet."
  use Proto.Packet, opcode: 0x1C09
  array :mobs, Proto.Packets.BriefinfoRegenmobCmd, count: :u8
end

defmodule Proto.Packets.BriefinfoBriefinfodeleteCmd do
  @moduledoc "0x1C0E NC_BRIEFINFO_BRIEFINFODELETE_CMD, server to client: the object left the receiver's sight."
  use Proto.Packet, opcode: 0x1C0E
  # official: hnd
  field :handle, :u16
end

defmodule Proto.Packets.MapLogoutCmd do
  @moduledoc "0x1805 NC_MAP_LOGOUT_CMD, server to client: the player left the map instance."
  use Proto.Packet, opcode: 0x1805
  # official: handle
  field :handle, :u16
end
