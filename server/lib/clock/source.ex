defmodule Clock.Source do
  @moduledoc "What a time source for `Clock` implements."

  @callback system_time(System.time_unit()) :: integer()
  @callback monotonic_time(System.time_unit()) :: integer()
end
