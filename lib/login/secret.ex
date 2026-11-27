defmodule Login.Secret do
  @moduledoc "Wraps a password text so that `inspect/1` (logs, crash reports) never prints it."

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: binary()}
end
