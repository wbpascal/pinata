defmodule Clock.Source do
  @moduledoc "What a time source for `Clock` implements."

  @callback system_time(System.time_unit()) :: integer()
  @callback monotonic_time(System.time_unit()) :: integer()
  @callback send_after(pid(), message :: term(), milliseconds :: non_neg_integer()) :: :ok
  @callback local_time(unix_seconds :: integer()) :: :calendar.datetime()
end
