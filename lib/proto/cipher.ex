defmodule Proto.Cipher do
  @moduledoc """
  The XOR-499 cipher, client to server only.

  It is applied to the whole body (opcode and payload), not to the length prefix. Server to client is plain.
  XOR is its own inverse, so `crypt/2` both decrypts and encrypts. The index starts at `seed % 499`, advances
  one per byte across packets and wraps to 0 after 498 (`docs/protocol/README.md` section 1.3).
  """

  @table Base.decode16!(
           "0759694a941194858c8805cba09ecd583a365b1a6a16febddf9402f82196c8e99ef7bfbdcfcdb27a009f4022fc11f90c2e12fba7740a7d78401e2ca02d06cba8b97eefde49ea4e13161680f43dc29ad486d7942417f4d665bd3fdbe4e10f50f6ec7a9a0c273d2466d322689c9a520be0f9a50b25da80490dfd3e77d156a8b7f40f9be80f5247f56f832022db0f0bb14385c1cba40b0219dff08becdb6c6d66ad45be89147e2f8910b89360d860def6fe6e9bca06c1759533cfc0b2e0cca5ce12f6e5b5b426c5b2184f2a5d261b654df545c98414dc7c124b189cc724e73c64ffd63a2cee8c8149396cb7dcbd94e232f7dd0afc020164ec4c940ab156f5c9a934de0f3827bc81300f7b3825fee83e29ba5543bf6b9f1f8a4952187f8af888245c4fe1a830878e501f2fd10cb4fd0abcdc1285e252ee4a5838abffc63db960640ab450d54089179ad585cfec0d7e817fe3c3040122ec27ccfa3e21a654c8de00b6df279ff625340785bfa7a5a5e0830c3d5d2040af60a36456f305c41c7d3798c3e85a6e5885a49a6b6af4a37b619b09401e604b32d951a4fef95d4e4afb4ad47c330233d59dce5baa5a7cd8f805fa1f2b8c725750ae6c1989ca01fcfc299b61126863654626c45b50aa2bbeef9a790223752c2013fdd95a7623f10bb5b859f99f7ae606e9a53ab450bf165898b39a6e36ee8deb",
           case: :lower
         )

  @type t :: 0..498

  @doc "Cipher state for a connection that was sent `seed`."
  @spec new(0..0xFFFF) :: t()
  def new(seed), do: rem(seed, 499)

  @doc "XORs `data` with the keystream; returns the result and the state for the next call."
  @spec crypt(t(), binary()) :: {binary(), t()}
  def crypt(idx, data), do: crypt(idx, data, [])

  defp crypt(idx, <<b, rest::binary>>, acc) do
    next = if idx >= 498, do: 0, else: idx + 1
    crypt(next, rest, [Bitwise.bxor(b, :binary.at(@table, idx)) | acc])
  end

  defp crypt(idx, <<>>, acc), do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), idx}

  @doc "The 499-byte key table."
  @spec table() :: binary()
  def table, do: @table
end
