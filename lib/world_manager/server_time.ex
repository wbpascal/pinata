defmodule WorldManager.ServerTime do
  @moduledoc "The server time of `0x0849` and `0x581C`: a local date-time as C `struct tm`, and the time zone in whole hours."

  @doc "The `struct tm` of a local date-time: `mon` 0-based, `year` minus 1900, `wday` 0 = Sunday, `yday` 0-based, `isdst` 0."
  @spec tm(:calendar.datetime()) :: Proto.Packets.Tm.t()
  def tm({{year, month, day} = date, {hour, min, sec}}) do
    %Proto.Packets.Tm{
      sec: sec,
      min: min,
      hour: hour,
      mday: day,
      mon: month - 1,
      year: year - 1900,
      wday: rem(:calendar.day_of_the_week(date), 7),
      yday: :calendar.date_to_gregorian_days(date) - :calendar.date_to_gregorian_days({year, 1, 1}),
      isdst: 0
    }
  end

  @doc "The whole hours between the local date-time of a Unix time and its UTC date-time."
  @spec time_zone(integer(), :calendar.datetime()) :: integer()
  def time_zone(unix, local) do
    utc = :calendar.system_time_to_universal_time(unix, :second)
    div(:calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc), 3600)
  end
end
