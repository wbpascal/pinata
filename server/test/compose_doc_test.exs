defmodule ComposeDocTest do
  use ExUnit.Case, async: true

  test "multi-node.md embeds compose.yaml and compose.toml verbatim" do
    doc = File.read!(Path.expand("../docs/user/multi-node.md", __DIR__))

    for file <- ["compose.yaml", "compose.toml"] do
      assert String.contains?(doc, File.read!(Path.expand("../#{file}", __DIR__))), "#{file} differs from multi-node.md"
    end
  end
end
