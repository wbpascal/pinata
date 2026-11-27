defmodule Proto.OpcodesTest do
  use ExUnit.Case, async: true

  @opcodes_path Path.expand("../fixtures/opcodes.json", __DIR__)

  defp selected(prefix) do
    for(
      entry <- @opcodes_path |> File.read!() |> JSON.decode!(),
      Enum.any?(entry["received_by"] || [], &String.starts_with?(&1, prefix)),
      do: entry["dept"] * 1024 + entry["cmd"]
    )
    |> Enum.sort()
  end

  test "the lists equal the selection over opcodes.json" do
    assert Proto.Opcodes.client("Zone") == selected("zone:ShineObjectClass::ShinePlayer:")
    assert Proto.Opcodes.client("WorldManager") == selected("wm:CParserClient:")
    assert length(Proto.Opcodes.client("Zone")) == 245
    assert length(Proto.Opcodes.client("WorldManager")) == 167
  end

  test "client?/2" do
    refute Proto.Opcodes.client?("Login", 0x2001)
    assert Proto.Opcodes.client?("Zone", 0x2001)
    assert Proto.Opcodes.client?("WorldManager", 0x7011)
    refute Proto.Opcodes.client?("Zone", 0xFFFE)
  end
end
