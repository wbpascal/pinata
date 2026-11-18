defmodule Persistence.Repo.SQLite do
  @moduledoc false
  use Ecto.Repo, otp_app: :pinata, adapter: Ecto.Adapters.SQLite3
end
