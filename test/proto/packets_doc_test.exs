defmodule Proto.PacketsDocTest do
  use ExUnit.Case, async: true

  test "packets.md is current" do
    assert File.read!("docs/technical/packets.md") == Proto.PacketsDoc.render(),
           "docs/technical/packets.md is out of date: run mix pinata.packets_doc"
  end
end
