# Consistency check of the release workflow (docs/technical/testing.md, "Release workflow"). Needs only Elixir:
#   elixir test/support/release_check.exs <out dir> [<tag>]
# Fails with exit status 1 when the files disagree (with a tag also on the changelog section). Otherwise writes into
# <out dir>: `version`, and, when CHANGELOG.md has a section for it, `title` and `notes.md` (the release text).
Code.require_file("release_notes.ex", __DIR__)

{out, tag} =
  case System.argv() do
    [out] ->
      {out, :none}

    [out, tag] ->
      {out, tag}

    _other ->
      IO.puts(:stderr, "usage: elixir test/support/release_check.exs <out dir> [<tag>]")
      System.halt(2)
  end

server = Path.expand("../..", __DIR__)

files = %{
  mix_exs: File.read!(Path.join(server, "mix.exs")),
  compose: File.read!(Path.join(server, "compose.yaml")),
  changelog: File.read!(Path.join(server, "../CHANGELOG.md"))
}

case ReleaseNotes.check(files, tag) do
  {:ok, %{version: version, section: section}} ->
    File.mkdir_p!(out)
    File.write!(Path.join(out, "version"), version)

    case section do
      {:ok, %{title: title, notes: notes}} ->
        File.write!(Path.join(out, "title"), title)
        File.write!(Path.join(out, "notes.md"), notes <> "\n")

      :error ->
        :ok
    end

    IO.puts("version #{version}: consistent")

  {:error, errors} ->
    Enum.each(errors, &IO.puts(:stderr, "release check: " <> &1))
    System.halt(1)
end
