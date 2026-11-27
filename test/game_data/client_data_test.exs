defmodule GameData.ClientDataTest do
  use ExUnit.Case, async: true

  alias GameData.ClientData

  @moduletag :tmp_dir

  defp captured_checksums do
    transcript =
      "../replay/transcripts/26_11_15_idle_in_world.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()

    %{payload: <<_handle::16, _name::binary-20, checksums::binary-1568>>} =
      Enum.find(transcript.packets, &(&1.opcode == 0x1801 and &1.dir == :client))

    checksums
  end

  defp flip(checksums, index) do
    at = index * 32 + 5
    <<head::binary-size(^at), byte, rest::binary>> = checksums
    head <> <<Bitwise.bxor(byte, 1)>> <> rest
  end

  test "the 49 checksums of the data directory equal those of the captured 0x1801" do
    ours = GameData.client_checksums()
    assert length(ours) == 49
    assert Enum.map_join(ours, &elem(&1, 1)) == captured_checksums()
    assert Enum.at(ours, 32) == {"MapViewInfo.shn", "d23b262f2066487f0b122e18eeb25eb4"}
  end

  test "first_difference/2 finds the lowest changed piece" do
    ours = GameData.client_checksums()
    captured = captured_checksums()
    assert ClientData.first_difference(ours, captured) == :none

    changed = flip(captured, 32)
    theirs = binary_part(changed, 32 * 32, 32)

    assert {32, "MapViewInfo.shn", "d23b262f2066487f0b122e18eeb25eb4", ^theirs} =
             ClientData.first_difference(ours, changed)

    assert {7, _table, _ours, _theirs} = ClientData.first_difference(ours, captured |> flip(32) |> flip(7))
  end

  test "a missing file is one line each", %{tmp_dir: tmp_dir} do
    assert {:error, lines} = ClientData.checksums(tmp_dir)
    assert length(lines) == 49
    assert "shn/View/MapViewInfo.shn: file not found (needed for the Client data check)" in lines
  end

  test "a truncated file is named" do
    assert GameData.Shn.decrypt(<<0::8*0x23>>) == {:error, "truncated SHN file"}
  end
end
