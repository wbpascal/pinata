defmodule ReleaseCheck do
  @moduledoc """
  The consistency check and the release text of the release workflow (`.github/workflows/release.yml`,
  `docs/technical/testing.md`, "Release workflow"). Pure functions on the file contents; `release_check.exs` reads
  the files and writes the result.
  """

  @image "ghcr.io/wbpascal/pinata"

  @type files :: %{mix_exs: String.t(), compose: String.t(), changelog: String.t()}
  @type section :: %{title: String.t(), text: String.t(), unreleased: boolean()}

  @doc """
  Checks the files against each other. `tag` is the pushed tag, or `:none` outside a tag run: then only the version
  of `mix.exs` and the image tag of `compose.yaml` are compared, and a missing or unreleased section is no error.
  """
  @spec check(files(), String.t() | :none) ::
          {:ok, %{version: String.t(), section: {:ok, section()} | :error}} | {:error, [String.t()]}
  def check(files, tag) do
    case version(files.mix_exs) do
      :error ->
        {:error, ["mix.exs has no version"]}

      {:ok, version} ->
        section = section(files.changelog, version)

        compose_error =
          image_tag(files.compose) != {:ok, version} &&
            "compose.yaml does not name #{@image}:#{version} (the version of mix.exs)"

        errors = Enum.filter([compose_error | tag_errors(tag, version, section)], &is_binary/1)
        if errors == [], do: {:ok, %{version: version, section: section}}, else: {:error, errors}
    end
  end

  defp tag_errors(:none, _version, _section), do: []

  defp tag_errors(tag, version, section) do
    [
      tag != "v" <> version && "the tag #{tag} is not v#{version} (the version of mix.exs)",
      section == :error && "CHANGELOG.md has no section for #{version}",
      match?({:ok, %{unreleased: true}}, section) && "the section #{version} of CHANGELOG.md is still marked unreleased"
    ]
  end

  @doc """
  The section of `version` in the changelog: the `## <version> ...` heading up to the next `## ` heading or the end.
  `title` is the heading without `## ` and without the ` (unreleased)` mark, `text` the text below it, trimmed.
  """
  @spec section(String.t(), String.t()) :: {:ok, section()} | :error
  def section(changelog, version) do
    {_before, from} =
      changelog
      |> String.split(~r/\r?\n/)
      |> Enum.split_while(&(not heading_of?(&1, version)))

    case from do
      [] ->
        :error

      [heading | rest] ->
        title = heading |> String.replace_prefix("## ", "") |> String.trim()
        body = Enum.take_while(rest, &(not String.starts_with?(&1, "## ")))

        {:ok,
         %{
           title: title |> String.replace_suffix("(unreleased)", "") |> String.trim(),
           text: body |> Enum.join("\n") |> String.trim(),
           unreleased: String.ends_with?(title, "(unreleased)")
         }}
    end
  end

  defp version(mix_exs) do
    case Regex.run(~r/^\s*version: "([^"]+)"/m, mix_exs) do
      [_line, version] -> {:ok, version}
      nil -> :error
    end
  end

  defp image_tag(compose) do
    case Regex.run(~r/^\s*image: #{Regex.escape(@image)}:(\S+)\s*$/m, compose) do
      [_line, tag] -> {:ok, tag}
      nil -> :error
    end
  end

  # "## 0.1.0" and "## 0.1.0 – Title", not "## 0.1.01".
  defp heading_of?(line, version), do: line == "## " <> version or String.starts_with?(line, "## #{version} ")
end
