defmodule Proto.Hand.World do
  @moduledoc "WORLD, 18 bytes (annotations/L01.json)."
  alias Proto.Wire

  @enforce_keys [:world_no, :world_name, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{world_no: 0..255, world_name: binary(), status: 0..255}

  @spec decode(binary()) :: {:ok, t()} | {:error, :bad_size}
  def decode(<<world_no::8, world_name::binary-size(16), status::8>>) do
    {:ok, %__MODULE__{world_no: world_no, world_name: Wire.cstr(world_name), status: status}}
  end

  def decode(_), do: {:error, :bad_size}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{world_no: world_no, world_name: world_name, status: status}) do
    <<world_no::8, Wire.pad(world_name, 16)::binary, status::8>>
  end
end
