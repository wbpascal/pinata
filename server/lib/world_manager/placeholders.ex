defmodule WorldManager.Placeholders do
  @moduledoc """
  The placeholder answers of the WorldManager at map entry (issue 88): packets whose data belongs to a later
  milestone, sent empty. Each function names its milestone; the milestone that owns the data replaces it.
  """

  alias Proto.Packets.CharClientNewbieGuideViewListCmd
  alias Proto.Packets.CharGuildAcademyCmd
  alias Proto.Packets.CharGuildCmd
  alias Proto.Packets.CharOptionGetShortcutsizeAck
  alias Proto.Packets.CharOptionGetWindowposAck
  alias Proto.Packets.HolyPromiseListCmd
  alias Proto.Packets.KqJoiningAlarmList
  alias Proto.Packets.PrisonGetAck

  @doc """
  Placeholder until milestone 6 (options): the answer `0x7005` to `0x7004`, no stored shortcut sizes (the client
  then uses its defaults). Issue 132 decides about the stored shortcuts.
  """
  @spec shortcut_size() :: CharOptionGetShortcutsizeAck.t()
  def shortcut_size, do: %CharOptionGetShortcutsizeAck{success: 0, data: <<0::size(24 * 8)>>}

  @doc "Placeholder until milestone 6 (options): the answer `0x700D` to `0x700C`, no stored window positions."
  @spec window_pos() :: CharOptionGetWindowposAck.t()
  def window_pos, do: %CharOptionGetWindowposAck{success: 0, data: <<0::size(392 * 8)>>}

  @doc "Placeholder until milestone 11 (prison): the answer `0x7C07` to `0x7C06`, not in prison (0x0DB1, 0 minutes)."
  @spec prison() :: PrisonGetAck.t()
  def prison, do: %PrisonGetAck{error: 0x0DB1, minutes: 0}

  @doc "Placeholder until milestone 8 (academy): `0x1097`, no guild academy."
  @spec guild_academy() :: CharGuildAcademyCmd.t()
  def guild_academy, do: %CharGuildAcademyCmd{academy_no: 0, is_member: 0}

  @doc "Placeholder until milestone 8 (guild): `0x1012`, no guild."
  @spec guild() :: CharGuildCmd.t()
  def guild, do: %CharGuildCmd{guild_no: 0}

  @doc "Placeholder until milestone 11 (holy promise): `0x9414`, no partner and no member, one part (3: start and end)."
  @spec holy_promise() :: HolyPromiseListCmd.t()
  def holy_promise,
    do: %HolyPromiseListCmd{up_name: "", up_logon: 0, up_level: 0, up_flags: 0, part: 3, count: 0}

  @doc "Placeholder until milestone 10 (Kingdom Quest): `0x5826`, no Kingdom Quest open to join."
  @spec kq_joining_alarm() :: KqJoiningAlarmList.t()
  def kq_joining_alarm, do: %KqJoiningAlarmList{count: 0}

  @doc """
  Placeholder until milestone 11 (newbie guide; the roadmap names no owner for it, milestone 11 holds the other
  leftovers): `0x10D9`, no guide seen.
  """
  @spec newbie_guide() :: CharClientNewbieGuideViewListCmd.t()
  def newbie_guide, do: %CharClientNewbieGuideViewListCmd{count: 0}
end
