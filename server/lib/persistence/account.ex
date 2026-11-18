defmodule Persistence.Account do
  @moduledoc "Private to `Persistence`: the `accounts` table and the rules for account names."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "accounts" do
    field :name, :string
    field :name_key, :string
    field :password_hash, :binary
    field :password_salt, :binary
    field :password_iterations, :integer
    field :blocked, :boolean
    field :login_able, :boolean
  end

  @doc "The comparison form of a name: no trailing spaces, ASCII letters lower-cased. `:error` when no stored name can match."
  @spec name_key(binary()) :: {:ok, String.t()} | :error
  def name_key(name) do
    rest = String.trim_trailing(name, " ")

    if rest != "" and printable?(rest), do: {:ok, String.downcase(rest, :ascii)}, else: :error
  end

  @spec valid_name?(binary()) :: boolean()
  def valid_name?(name), do: byte_size(name) in 1..255 and printable?(name)

  defp printable?(name), do: Enum.all?(:binary.bin_to_list(name), &(&1 in 0x21..0x7E))
end
