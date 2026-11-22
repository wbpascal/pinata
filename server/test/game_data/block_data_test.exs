defmodule GameData.BlockDataTest do
  use ExUnit.Case, async: true

  alias GameData.BlockData

  @dir System.fetch_env!("PINATA_TEST_DATA_DIR")
  @moduletag :tmp_dir

  defp put(dir, file, bpr, rows, bits) do
    File.mkdir_p!(Path.join(dir, "BlockInfo"))
    File.write!(Path.join(dir, "BlockInfo/#{file}"), <<bpr::little-32, rows::little-32, bits::binary>>)
  end

  # 2 bytes per row x 16 rows: 16 x 16 cells
  defp map(bits), do: %BlockData{bytes_per_row: 2, rows: 16, bits: bits}
  defp free, do: map(:binary.copy(<<0>>, 32))
  defp full, do: map(:binary.copy(<<255>>, 32))

  test "every plain field map checks" do
    for %{map_id_client: name} <- GameData.plain_field_maps(), do: assert(BlockData.check(@dir, name) == :ok)
  end

  test "real data" do
    assert {:ok, %BlockData{bytes_per_row: bpr, rows: rows, bits: bits}} = BlockData.load(@dir, "Wedding")
    assert byte_size(bits) == bpr * rows

    {:ok, %{bits: merged}} = BlockData.load(@dir, "RouTemDn01")
    <<_::64, a::binary>> = File.read!(Path.join(@dir, "BlockInfo/RouTemDn01.shbd"))
    <<_::64, b::binary>> = File.read!(Path.join(@dir, "BlockInfo/RouTemDn01.shab"))

    expected =
      for {x, y} <- Enum.zip(:binary.bin_to_list(a), :binary.bin_to_list(b)), into: <<>>, do: <<Bitwise.bor(x, y)>>

    assert merged == expected
  end

  test "errors", %{tmp_dir: dir} do
    nope = {:error, "BlockInfo/Nope.shbd: file not found"}
    assert BlockData.check(dir, "Nope") == nope
    assert BlockData.load(dir, "Nope") == nope

    File.mkdir_p!(Path.join(dir, "BlockInfo"))
    File.write!(Path.join(dir, "BlockInfo/Bad.shbd"), "12345")

    for f <- [&BlockData.check/2, &BlockData.load/2],
        do: assert({:error, "BlockInfo/Bad.shbd" <> _} = f.(dir, "Bad"))

    put(dir, "Bad.shbd", 2, 16, "12345")
    assert {:error, "BlockInfo/Bad.shbd" <> _} = BlockData.check(dir, "Bad")
    assert {:error, "BlockInfo/Bad.shbd" <> _} = BlockData.load(dir, "Bad")
    put(dir, "Bad.shbd", 0, 16, "")
    assert {:error, "BlockInfo/Bad.shbd" <> _} = BlockData.check(dir, "Bad")
    assert {:error, "BlockInfo/Bad.shbd" <> _} = BlockData.load(dir, "Bad")
  end

  test "the name on disk is in the message", %{tmp_dir: dir} do
    put(dir, "bad.shbd", 2, 16, "1")
    assert {:error, "BlockInfo/bad.shbd" <> _} = BlockData.load(dir, "Bad")
  end

  test "shab", %{tmp_dir: dir} do
    put(dir, "M.shbd", 2, 16, :binary.copy(<<0>>, 32))
    assert {:ok, %{bits: bits}} = BlockData.load(dir, "M")
    assert bits == :binary.copy(<<0>>, 32)

    put(dir, "M.shab", 2, 16, <<0x04, 0::248>>)
    assert {:ok, %{bits: <<0x04, 0::248>>} = b} = BlockData.load(dir, "M")
    assert BlockData.blocked?(b, (2 * 6.25) |> round(), 0)

    put(dir, "M.shab", 4, 8, :binary.copy(<<0>>, 32))
    assert {:error, "BlockInfo/M.shab" <> _} = BlockData.load(dir, "M")
    File.write!(Path.join(dir, "BlockInfo/M.shab"), "xx")
    assert {:error, "BlockInfo/M.shab" <> _} = BlockData.load(dir, "M")
  end

  test "blocked?" do
    b = map(<<0x02, 0::248>>)
    assert BlockData.blocked?(b, 7, 0)
    refute BlockData.blocked?(b, 6, 0)
    assert BlockData.blocked?(free(), 100, 0)
    assert BlockData.blocked?(free(), 0, 100)
    assert BlockData.blocked?(free(), -1, 0)
  end

  test "free_cell?" do
    # cell (5, 5) free: byte 2 * 5 + 0, bit 5
    bits = :binary.copy(<<255>>, 10) <> <<255 - 32, 255>> <> :binary.copy(<<255>>, 20)
    b = map(bits)
    assert BlockData.free_cell?(b, 25, 25)
    refute BlockData.free_cell?(b, 12, 12)
  end

  test "line_blocked?" do
    refute BlockData.line_blocked?(free(), {10, 10}, {90, 10}, 2)

    for {a, z} <- [{{10, 10}, {90, 10}}, {{10, 10}, {10, 90}}, {{90, 90}, {10, 10}}],
        do: assert(BlockData.line_blocked?(full(), a, z, 2))

    refute BlockData.line_blocked?(full(), {10, 10}, {11, 10}, 2)
    refute BlockData.line_blocked?(full(), {10, 10}, {10, 10}, 2)
    refute BlockData.line_blocked?(full(), {10, 10}, {30, 10}, 100)
  end
end
