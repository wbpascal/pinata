defmodule GameData.Schema do
  @moduledoc """
  The behaviour of a schema module: one per data table that the server reads (ADR 0006).

  A schema lists only the columns the server reads. A column of the file that the schema does not list is ignored; a
  listed column that the file lacks is a structural mismatch.
  """

  @type column_type :: :integer | :string

  @type t :: %{
          # path relative to the data directory
          source: {:shn | :csv, String.t()},
          # a field name, or :row = the 1-based data row number
          key: atom(),
          # field => {column name in the file, type}
          columns: [{atom(), {String.t(), column_type()}}],
          # fields with a non-unique index, rows kept in file order
          indexes: [atom()],
          # field => schema whose key the value must be
          references: [{atom(), module()}]
        }

  @callback __schema__() :: t()
end
