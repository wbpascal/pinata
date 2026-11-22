defmodule Proto.Packets.CharParameterData do
  @moduledoc """
  CHAR_PARAMETER_DATA (232 bytes, nested in 0x1802): experience bounds, the 16 stat pairs `{u32 base, u32 change}`
  (Strength, Constitute, Dexterity, Intelligence, Wizdom, MentalPower, WClow, WChigh, AC, TH, TB, MAlow, MAhigh, MR,
  MH, MB), the maxima, then power stones, guard stones and the four resistance pairs.
  """
  use Proto.Packet
  # official: PrevExp
  field :prev_exp, :u64
  # official: NextExp
  field :next_exp, :u64
  # official: Strength … MB, 16 x {base, change}
  field :stats, {:bytes, 128}
  # official: MaxHp
  field :max_hp, :u32
  # official: MaxSp
  field :max_sp, :u32
  # official: MaxLp
  field :max_lp, :u32
  # official: MaxAp
  field :max_ap, :u32
  # official: MaxHPStone
  field :max_hp_stone, :u32
  # official: MaxSPStone
  field :max_sp_stone, :u32
  # official: PwrStone, GrdStone, PainRes, RestraintRes, CurseRes, ShockRes
  field :rest, {:bytes, 64}
end

defmodule Proto.Packets.CharClientBaseCmd do
  @moduledoc "0x1038 NC_CHAR_CLIENT_BASE_CMD, server to client: the character's base data, first packet of the map login."
  use Proto.Packet, opcode: 0x1038
  field :chrregnum, :u32
  # official: charid
  field :name, {:char, 20}
  # official: slotno
  field :slot, :u8
  # official: Level
  field :level, :u8
  # official: Experience
  field :exp, :u64
  # official: CurPwrStone
  field :power_stones, :u16
  # official: CurGrdStone
  field :guard_stones, :u16
  # official: CurHPStone
  field :hp_stones, :u16
  # official: CurSPStone
  field :sp_stones, :u16
  # official: CurHP
  field :hp, :u32
  # official: CurSP
  field :sp, :u32
  # official: CurLP
  field :lp, :u32
  field :fame, :u32
  # official: Cen
  field :money, :u64
  # official: logininfo.currentmap
  field :map, {:char, 12}
  # official: logininfo.currentcoord.xy.x
  field :x, :u32
  # official: logininfo.currentcoord.xy.y
  field :y, :u32
  # official: logininfo.currentcoord.dir
  field :dir, :u8
  # official: statdistribute (Strength, Constitute, Dexterity, Intelligence, MentalPower, RedistributePoint)
  field :stat_distribute, {:bytes, 6}
  # official: pkyellowtime
  field :pk_yellow_time, :u8
  # official: pkcount
  field :pk_count, :u32
  # official: prisonmin
  field :prison_minutes, :u16
  # official: adminlevel
  field :admin_level, :u8
  # official: flags
  field :flags, :u32
end

defmodule Proto.Packets.CharClientShapeCmd do
  @moduledoc "0x1039 NC_CHAR_CLIENT_SHAPE_CMD, server to client: race, class, gender and the look (as in AVATAR)."
  use Proto.Packet, opcode: 0x1039
  bits gender: 1, chrclass: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
end

defmodule Proto.Packets.CharClientQuestDoingCmd do
  @moduledoc "0x103A NC_CHAR_CLIENT_QUEST_DOING_CMD, server to client: the running quests (the list is milestone 5)."
  use Proto.Packet, opcode: 0x103A
  field :chrregnum, :u32
  # official: bNeedClear
  field :need_clear, :u8
  # official: nNumOfDoingQuest
  field :count, :u8
end

defmodule Proto.Packets.CharClientQuestDoneCmd do
  @moduledoc "0x103B NC_CHAR_CLIENT_QUEST_DONE_CMD, server to client: the done quests (the list is milestone 5)."
  use Proto.Packet, opcode: 0x103B
  field :chrregnum, :u32
  # official: nTotalDoneQuest
  field :total, :u16
  # official: nTotalDoneQuestSize
  field :total_size, :u16
  # official: nDoneQuestCount
  field :count, :u16
  # official: nIndex
  field :index, :u16
end

defmodule Proto.Packets.CharClientQuestReadCmd do
  @moduledoc "0x10CE NC_CHAR_CLIENT_QUEST_READ_CMD, server to client: the read quest texts (the list is milestone 5)."
  use Proto.Packet, opcode: 0x10CE
  field :chrregnum, :u32
  # official: nNumOfReadQuest
  field :count, :u16
end

defmodule Proto.Packets.CharClientQuestRepeatCmd do
  @moduledoc "0x10D7 NC_CHAR_CLIENT_QUEST_REPEAT_CMD, server to client: the repeatable quests (the list is milestone 5)."
  use Proto.Packet, opcode: 0x10D7
  field :chrregnum, :u32
  # official: nNumOfRepeatQuest
  field :count, :u16
end

defmodule Proto.Packets.CharClientSkillCmd do
  @moduledoc "0x103D NC_CHAR_CLIENT_SKILL_CMD, server to client: the skills (the list is milestone 4)."
  use Proto.Packet, opcode: 0x103D
  # official: restempow
  field :rest_empower, :u8
  # official: PartMark.bIsStart|bIsEnd|nOrder
  field :part_mark, :u8
  # official: nMaxNum
  field :max_count, :u16
  # official: skill.chrregnum
  field :chrregnum, :u32
  # official: skill.number
  field :count, :u16
end

defmodule Proto.Packets.CharClientPassiveCmd do
  @moduledoc "0x103E NC_CHAR_CLIENT_PASSIVE_CMD, server to client: the passive skills (the list is milestone 4)."
  use Proto.Packet, opcode: 0x103E
  # official: number
  field :count, :u16
end

defmodule Proto.Packets.CharClientItemCmd do
  @moduledoc "0x1047 NC_CHAR_CLIENT_ITEM_CMD, server to client: the items of one box (the list is milestone 3)."
  use Proto.Packet, opcode: 0x1047
  # official: numofitem
  field :count, :u8
  field :box, :u8
  field :flag, :u8
end

defmodule Proto.Packets.CharClientChartitleCmd do
  @moduledoc "0x1049 NC_CHAR_CLIENT_CHARTITLE_CMD, server to client: the current title and the titles (milestone 6)."
  use Proto.Packet, opcode: 0x1049
  # official: CurrentTitle
  field :current_title, :u8
  # official: CurrentTitleElement
  field :current_element, :u8
  # official: CurrentTitleMobID
  field :current_mob_id, :u16
  # official: NumOfTitle
  field :count, :u16
end

defmodule Proto.Packets.CharClientChargedbuffCmd do
  @moduledoc "0x104A NC_CHAR_CLIENT_CHARGEDBUFF_CMD, server to client: the charged buffs (the list is milestone 9)."
  use Proto.Packet, opcode: 0x104A
  # official: NumOfChargedBuff
  field :count, :u16
end

defmodule Proto.Packets.CharClientGameCmd do
  @moduledoc "0x1048 NC_CHAR_CLIENT_GAME_CMD, server to client: party and raid number, 0xFFFF for none."
  use Proto.Packet, opcode: 0x1048
  # official: partyno
  field :party_no, :u16
  # official: nRaidNo
  field :raid_no, :u16
end

defmodule Proto.Packets.CharClientCoininfoCmd do
  @moduledoc "0x10DE NC_CHAR_CLIENT_COININFO_CMD, server to client: coins and the coins still exchangeable."
  use Proto.Packet, opcode: 0x10DE
  # official: nCoin
  field :coin, :u64
  # official: nExchangedCoin
  field :exchangeable, :u64
end

defmodule Proto.Packets.QuestResetTimeClientCmd do
  @moduledoc "0x441E NC_QUEST_RESET_TIME_CLIENT_CMD, server to client: the reset times of the year, month, week and day quests (Unix time)."
  use Proto.Packet, opcode: 0x441E
  # official: tResetYearQuest
  field :year, :u32
  # official: tResetMonthQuest
  field :month, :u32
  # official: tResetWeekQuest
  field :week, :u32
  # official: tResetDayQuest
  field :day, :u32
end

defmodule Proto.Packets.MapLoginAck do
  @moduledoc "0x1802 NC_MAP_LOGIN_ACK, server to client: the object handle, the parameter block and the position."
  use Proto.Packet, opcode: 0x1802
  # official: charhandle
  field :handle, :u16
  field :param, Proto.Packets.CharParameterData
  # official: logincoord.x
  field :x, :u32
  # official: logincoord.y
  field :y, :u32
end

defmodule Proto.Packets.MapLogincompleteCmd do
  @moduledoc "0x1803 NC_MAP_LOGINCOMPLETE_CMD, empty, client to server: the client has loaded the map."
  use Proto.Packet, opcode: 0x1803
end

defmodule Proto.Packets.CharClientCardcollectCmd do
  @moduledoc "0x10E4 NC_CHAR_CLIENT_CARDCOLLECT_CMD, server to client: the card collection (the list is milestone 11)."
  use Proto.Packet, opcode: 0x10E4
  field :chrregnum, :u32
  # official: number
  field :count, :u16
end

defmodule Proto.Packets.CharClientCardcollectBookmarkCmd do
  @moduledoc "0x10E7 NC_CHAR_CLIENT_CARDCOLLECT_BOOKMARK_CMD, server to client: the card bookmarks (the list is milestone 11)."
  use Proto.Packet, opcode: 0x10E7
  field :chrregnum, :u32
  field :count, :u16
end

defmodule Proto.Packets.CharClientCardcollectRewardCmd do
  @moduledoc "0x10EA NC_CHAR_CLIENT_CARDCOLLECT_REWARD_CMD, server to client: the card rewards (the list is milestone 11)."
  use Proto.Packet, opcode: 0x10EA
  field :chrregnum, :u32
  field :count, :u16
end

defmodule Proto.Packets.BriefinfoUnequipCmd do
  @moduledoc "0x1C04 NC_BRIEFINFO_UNEQUIP_CMD, server to client: the slot of an object shows nothing."
  use Proto.Packet, opcode: 0x1C04
  field :handle, :u16
  field :slot, :u8
end

defmodule Proto.Packets.BriefinfoChangedecorateCmd do
  @moduledoc "0x1C02 NC_BRIEFINFO_CHANGEDECORATE_CMD, server to client: a decoration or costume item in a slot of an object."
  use Proto.Packet, opcode: 0x1C02
  field :handle, :u16
  field :item, :u16
  # official: nSlotNum
  field :slot, :u8
end

defmodule Proto.Packets.BriefinfoChangeupgradeCmd do
  @moduledoc "0x1C03 NC_BRIEFINFO_CHANGEUPGRADE_CMD, server to client: an armour, shield or boot item with its upgrade."
  use Proto.Packet, opcode: 0x1C03
  field :handle, :u16
  field :item, :u16
  field :upgrade, :u8
  # official: nSlotNum
  field :slot, :u8
end

defmodule Proto.Packets.BriefinfoChangeweaponCmd do
  @moduledoc "0x1C05 NC_BRIEFINFO_CHANGEWEAPON_CMD, server to client: a weapon with its upgrade and its licence mob (0xFFFF none)."
  use Proto.Packet, opcode: 0x1C05
  field :handle, :u16
  field :item, :u16
  field :upgrade, :u8
  # official: nSlotNum
  field :slot, :u8
  # official: currentmobid
  field :current_mob_id, :u16
  # official: currentkilllevel
  field :current_kill_level, :u8
end

defmodule Proto.Packets.KqTeamTypeCmd do
  @moduledoc "0x583A NC_KQ_TEAM_TYPE_CMD, server to client: the Kingdom Quest team."
  use Proto.Packet, opcode: 0x583A
  # official: nTeamType
  field :team_type, :u8
end

defmodule Proto.Packets.CharStatRemainpointCmd do
  @moduledoc "0x105B NC_CHAR_STAT_REMAINPOINT_CMD, server to client: the unspent stat points."
  use Proto.Packet, opcode: 0x105B
  # official: remain
  field :remain, :u8
end

defmodule Proto.Packets.ActMovespeedCmd do
  @moduledoc "0x203E NC_ACT_MOVESPEED_CMD, server to client: walk and run speed."
  use Proto.Packet, opcode: 0x203E
  # official: walkspeed
  field :walk, :u16
  # official: runspeed
  field :run, :u16
end

defmodule Proto.Packets.ChargedBoothslotsizeCmd do
  @moduledoc "0x9010 NC_CHARGED_BOOTHSLOTSIZE_CMD, server to client: the number of booth slots."
  use Proto.Packet, opcode: 0x9010
  # official: boothsize
  field :size, :u8
end

defmodule Proto.Packets.MapCanUseReviveitemCmd do
  @moduledoc "0x182B NC_MAP_CAN_USE_REVIVEITEM_CMD, server to client: 1 = revive items can be used on the map."
  use Proto.Packet, opcode: 0x182B
  # official: bCanUseReviveItem
  field :can_use, :u8
end

defmodule Proto.Packets.ActNoticeCmd do
  @moduledoc "0x2011 NC_ACT_NOTICE_CMD, server to client: a notice line. The original never writes the first byte (Z09-B54); we send 0."
  use Proto.Packet, opcode: 0x2011
  field :unused, :u8
  field :text, {:counted, :u8}
end

defmodule Proto.Packets.CharUseitemMinimonInfoClientCmd do
  @moduledoc "0x1123 NC_CHAR_USEITEM_MINIMON_INFO_CLIENT_CMD, server to client: the item lists of the mini-mons, 0xFFFF for none."
  use Proto.Packet, opcode: 0x1123
  # official: UseItemMinimonInfo.bNormalItem
  field :normal, :u8
  # official: UseItemMinimonInfo.bChargedItem
  field :charged, :u8
  # official: UseItemMinimonInfo.NormalItemList
  field :normal_items, {:u16s, 12}
  # official: UseItemMinimonInfo.ChargedItemList
  field :charged_items, {:u16s, 12}
end

defmodule Proto.Packets.CharAdminLevelInformCmd do
  @moduledoc "0x10C6 NC_CHAR_ADMIN_LEVEL_INFORM_CMD, server to client: the admin level of the character."
  use Proto.Packet, opcode: 0x10C6
  # official: nAdminLevel
  field :admin_level, :u8
end

defmodule Proto.Packets.SkillItemactioncooltimeCmd do
  @moduledoc "0x482C NC_SKILL_ITEMACTIONCOOLTIME_CMD, server to client: the item action cool-downs (the list is milestone 4)."
  use Proto.Packet, opcode: 0x482C
  field :count, :u16
end

defmodule Proto.Packets.CharMysteryvaultUiStateCmd do
  @moduledoc "0x10D4 NC_CHAR_MYSTERYVAULT_UI_STATE_CMD, server to client: the state of the mystery vault window."
  use Proto.Packet, opcode: 0x10D4
  # official: mystery_vault
  field :state, :u8
end

defmodule Proto.Packets.MapFieldAttributeCmd do
  @moduledoc "0x1827 NC_MAP_FIELD_ATTRIBUTE_CMD, server to client: FIELD_MAP_TYPE of the map (`FieldList` column `KQ`)."
  use Proto.Packet, opcode: 0x1827
  # official: eFieldMapType
  field :map_type, :u32
end

defmodule Proto.Packets.ParamChange do
  @moduledoc "One parameter of 0x1035: the CHAR_PARAMETER flag and its value."
  use Proto.Packet
  field :flag, :u8
  field :value, :u32
end

defmodule Proto.Packets.CharChangeparamchangeCmd do
  @moduledoc "0x1035 NC_CHAR_CHANGEPARAMCHANGE_CMD, server to client: changed parameters."
  use Proto.Packet, opcode: 0x1035
  array :params, Proto.Packets.ParamChange, count: :u8
end

defmodule Proto.Packets.BatHpchangeCmd do
  @moduledoc "0x240E NC_BAT_HPCHANGE_CMD, server to client: the current HP and a change counter."
  use Proto.Packet, opcode: 0x240E
  field :hp, :u32
  # official: hpchangeorder
  field :order, :u16
end

defmodule Proto.Packets.BatSpchangeCmd do
  @moduledoc "0x240F NC_BAT_SPCHANGE_CMD, server to client: the current SP."
  use Proto.Packet, opcode: 0x240F
  field :sp, :u32
end

defmodule Proto.Packets.BatLpchangeCmd do
  @moduledoc "0x245F NC_BAT_LPCHANGE_CMD, server to client: the current LP."
  use Proto.Packet, opcode: 0x245F
  field :lp, :u32
end

defmodule Proto.Packets.ActEndoftradeCmd do
  @moduledoc "0x200B NC_ACT_ENDOFTRADE_CMD, empty, client to server."
  use Proto.Packet, opcode: 0x200B
end

defmodule Proto.Packets.ItemRewardinvenopenReq do
  @moduledoc "0x302C NC_ITEM_REWARDINVENOPEN_REQ, client to server: open a page of the reward inventory."
  use Proto.Packet, opcode: 0x302C
  field :page, :u16
end

defmodule Proto.Packets.ItemRewardinvenopenAck do
  @moduledoc "0x302D NC_ITEM_REWARDINVENOPEN_ACK, server to client. The original adds one unwritten byte (P02-B3); we send 0."
  use Proto.Packet, opcode: 0x302D
  # official: itemcounter
  field :count, :u8
  field :stray, :u8
end

defmodule Proto.Packets.ItemChargedinvenopenReq do
  @moduledoc "0x3020 NC_ITEM_CHARGEDINVENOPEN_REQ, client to server: open a page of the charged inventory."
  use Proto.Packet, opcode: 0x3020
  field :page, :u16
end

defmodule Proto.Packets.ItemChargedinvenopenAck do
  @moduledoc "0x3021 NC_ITEM_CHARGEDINVENOPEN_ACK, server to client: the charged items of a page."
  use Proto.Packet, opcode: 0x3021
  # official: ErrorCode
  field :error, :u16
  # official: nPartMark
  field :part_mark, :u8
  # official: NumOfChargedItem
  field :count, :u16
end
