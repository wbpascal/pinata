defmodule WorldManager.ServerTimeTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.MiscServerTimeNotifyCmd
  alias Proto.Packets.Tm

  # 26_11_15_idle_in_world, transcript index 125: the 0x0849 of the WorldManager burst
  @captured "010000000a0000000a0000000f0000000a0000007e000000000000003e0100000000000001"

  test "the captured server time" do
    local = {{2026, 11, 15}, {10, 10, 1}}
    tm = WorldManager.ServerTime.tm(local)

    assert tm == %Tm{sec: 1, min: 10, hour: 10, mday: 15, mon: 10, year: 126, wday: 0, yday: 318, isdst: 0}
    assert WorldManager.ServerTime.time_zone(1_794_733_801, local) == 1

    assert Base.encode16(MiscServerTimeNotifyCmd.encode(%MiscServerTimeNotifyCmd{tm: tm, time_zone: 1}), case: :lower) ==
             @captured
  end

  test "1 January is day 0 and a zone west of UTC is negative" do
    assert %Tm{yday: 0, mon: 0, wday: 4} = WorldManager.ServerTime.tm({{2026, 1, 1}, {0, 0, 0}})
    assert WorldManager.ServerTime.time_zone(1_794_733_801, {{2026, 11, 15}, {4, 10, 1}}) == -5
  end
end
