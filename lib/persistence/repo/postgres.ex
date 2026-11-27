defmodule Persistence.Repo.Postgres do
  @moduledoc false
  use Ecto.Repo, otp_app: :pinata, adapter: Ecto.Adapters.Postgres
end
