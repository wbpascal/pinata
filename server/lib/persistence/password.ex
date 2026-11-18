defmodule Persistence.Password do
  @moduledoc "Private to `Persistence`: PBKDF2-HMAC-SHA256 with a per-account salt and a stored iteration count."

  @spec hash(binary()) :: {binary(), binary(), pos_integer()}
  def hash(password) do
    salt = Random.bytes(16)
    iterations = Application.get_env(:pinata, :password_iterations, 600_000)
    {derive(password, salt, iterations), salt, iterations}
  end

  @spec verify?(binary(), binary(), binary(), pos_integer()) :: boolean()
  def verify?(password, hash, salt, iterations), do: :crypto.hash_equals(derive(password, salt, iterations), hash)

  defp derive(password, salt, iterations), do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
end
