defmodule ReleaseCheckTest do
  use ExUnit.Case, async: true

  @mix_exs ~s(  def project do\n    [\n      app: :pinata,\n      version: "0.1.0",\n)
  @compose "x-node: &node\n  image: ghcr.io/wbpascal/pinata:0.1.0\n"
  @changelog """
  # Changelog

  ## 0.1.01 – Not this one

  wrong

  ## 0.1.0 – Login to character select

  ### New

  - Line one.
  - Line two.

  ## 0.0.9 – Older

  old
  """

  defp files(overrides \\ []),
    do: Map.merge(%{mix_exs: @mix_exs, compose: @compose, changelog: @changelog}, Map.new(overrides))

  describe "section/2" do
    test "takes the heading of exactly the version, up to the next section" do
      assert {:ok, %{title: "0.1.0 – Login to character select", text: "### New\n\n- Line one.\n- Line two."}} =
               ReleaseCheck.section(@changelog, "0.1.0")
    end

    test "the last section runs to the end, a heading without title counts" do
      assert {:ok, %{title: "0.0.9 – Older", text: "old", unreleased: false}} =
               ReleaseCheck.section(@changelog, "0.0.9")

      assert {:ok, %{title: "0.2.0", text: "x"}} = ReleaseCheck.section("## 0.2.0\nx\n", "0.2.0")
    end

    test "the unreleased mark is not part of the title" do
      assert {:ok, %{title: "0.1.0 – T", unreleased: true}} =
               ReleaseCheck.section("## 0.1.0 – T (unreleased)\n\nx\n", "0.1.0")
    end

    test "no section for a prefix of a version, or for a missing one" do
      assert :error = ReleaseCheck.section("## 0.1.01 – X\n", "0.1.0")
      assert :error = ReleaseCheck.section(@changelog, "0.3.0")
    end
  end

  describe "check/2" do
    test "consistent files pass, with and without a tag" do
      assert {:ok, %{version: "0.1.0", section: {:ok, _section}}} = ReleaseCheck.check(files(), "v0.1.0")
      assert {:ok, %{version: "0.1.0"}} = ReleaseCheck.check(files(), :none)
    end

    test "the image tag of compose.yaml differs from mix.exs" do
      compose = "  image: ghcr.io/wbpascal/pinata:0.0.9\n"
      assert {:error, ["server/compose.yaml does not name" <> _]} = ReleaseCheck.check(files(compose: compose), :none)
    end

    test "the tag differs from mix.exs" do
      assert {:error, ["the tag v0.1.1 is not v0.1.0" <> _]} = ReleaseCheck.check(files(), "v0.1.1")
    end

    test "no changelog section for the version: an error on a tag run only" do
      changelog = "# Changelog\n\n## 0.1.01 – X\n"

      assert {:error, ["CHANGELOG.md has no section for 0.1.0"]} =
               ReleaseCheck.check(files(changelog: changelog), "v0.1.0")

      assert {:ok, %{section: :error}} = ReleaseCheck.check(files(changelog: changelog), :none)
    end

    test "the section is marked unreleased: an error on a tag run only" do
      changelog = "## 0.1.0 – T (unreleased)\n\nx\n"
      assert {:error, [message]} = ReleaseCheck.check(files(changelog: changelog), "v0.1.0")
      assert message =~ "still marked unreleased"
      assert {:ok, %{section: {:ok, %{unreleased: true}}}} = ReleaseCheck.check(files(changelog: changelog), :none)
    end

    test "the repository's own files are consistent" do
      server = Path.expand("..", __DIR__)

      files = %{
        mix_exs: File.read!(Path.join(server, "mix.exs")),
        compose: File.read!(Path.join(server, "compose.yaml")),
        changelog: File.read!(Path.join(server, "../CHANGELOG.md"))
      }

      assert {:ok, %{section: {:ok, _section}}} = ReleaseCheck.check(files, :none)
    end
  end
end
