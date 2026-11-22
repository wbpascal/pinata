defmodule Settings.Doc do
  @moduledoc "Renders `docs/user/settings.md` from `Settings.Schema`."

  alias Settings.Schema

  @doc "The whole page as Markdown."
  @spec render() :: String.t()
  def render do
    rows = Schema.schema() |> rows("") |> Enum.map_join("\n", fn row -> "| " <> Enum.join(row, " | ") <> " |" end)
    String.replace(template(), "ROWS", rows)
  end

  defp rows(schema, path) do
    Enum.flat_map(schema, fn {key, spec} ->
      case spec[:type] do
        :keyword_list -> rows(spec[:keys], "#{path}#{key}.")
        {:list, {:keyword_list, keys}} -> rows(keys, "[[#{path}#{key}]] ")
        _leaf -> [["`#{path}#{key}`", type(spec), default(spec), spec[:doc]]]
      end
    end)
  end

  defp type(spec) do
    case {spec[:type_doc], spec[:type]} do
      {nil, :string} -> "string"
      {nil, :boolean} -> "boolean"
      {nil, :non_neg_integer} -> "integer, 0 or more"
      {nil, {:list, :string}} -> "list of strings"
      {type_doc, _type} when is_binary(type_doc) -> type_doc
    end
  end

  defp default(spec) do
    case Keyword.fetch(spec, :default) do
      {:ok, value} -> "`#{inspect(value)}`"
      :error -> "see description"
    end
  end

  defp template do
    """
    # Settings

    <!-- Generated from `Settings.Schema` by `Settings.Doc.render/0`. Do not edit by hand: see "Settings" in server/docs/technical/README.md. -->

    A node reads its settings once, at start-up, from one TOML file. Every key has a default, so the file is optional:
    with no file the node starts in single-node mode on the data directory `./data`, which must exist (see [`install.md`](install.md)).

    ## Environment variables

    | Variable | Default | Meaning |
    |---|---|---|
    | `PINATA_CONFIG` | `pinata.toml` in the working directory | Path of the settings file. The default file may be missing; a path set here must exist. |
    | `PINATA_PARTS` | `login,world_manager,zone` | The parts this node starts, separated by commas. A part that is not listed opens no port. |
    | `DATABASE_URL` | not set | Overrides `database.url`, so the secret can stay out of the file. |
    | `OTEL_EXPORTER_OTLP_ENDPOINT` | not set | The OTLP endpoint when `telemetry.otlp_enabled` is true and `telemetry.otlp_endpoint` is not set. |

    ## Keys

    | Key | Type | Default | Meaning |
    |---|---|---|---|
    ROWS

    A key with a dot is written inside a table: `login.port` is `port` under `[login]`. Each world is one `[[world]]` table.

    ```toml
    public_host = "203.0.113.7"

    [login]
    port = 9010

    [[world]]
    number = 0
    name = "INITIO"
    ```

    ## OpenTelemetry variables

    With `telemetry.otlp_enabled = true` the standard variables of the OpenTelemetry SDK work as upstream documents them:
    `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_SERVICE_NAME` (default
    `pinata`) and the others ([SDK configuration](https://opentelemetry.io/docs/languages/sdk-configuration/),
    [`opentelemetry_exporter`](https://hexdocs.pm/opentelemetry_exporter/)). `OTEL_TRACES_SAMPLER`, when set, replaces
    `telemetry.trace_ratio`. With `telemetry.otlp_enabled = false` none of them has an effect.

    ## Start-up errors

    The node checks the whole file before it starts anything. A key it does not know, a value of the wrong type, a file
    that is not valid TOML, a `PINATA_CONFIG` path that cannot be read and an unknown name in `PINATA_PARTS` are all
    errors. It prints every problem at once to standard error, each with its key, its value and what was expected, and
    does not start:

    ```
    Invalid settings, the node does not start:
      bogus: unknown key
      login.port: invalid value for :port option: expected one of 1..65535, got: 0
    ```

    After the settings the node loads its game data. If `data_dir` does not exist, or a data table is damaged, it prints
    the problems and does not start. Both cases are described in [`install.md`](install.md).
    """
  end
end
