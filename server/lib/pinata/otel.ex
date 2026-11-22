defmodule Pinata.Otel do
  @moduledoc """
  Starts the OpenTelemetry SDK after the settings are read and turns the `:telemetry` spans into OpenTelemetry spans
  and histograms (ADR 0011). With `telemetry.otlp_enabled = false` the SDK runs with no exporter and no reader:
  nothing is exported and no connection is opened. The only module that names the OpenTelemetry API.
  See `docs/technical/telemetry.md`.
  """

  use Boundary, top_level?: true, deps: [Pinata.Figures]

  require Logger
  require OpenTelemetryAPIExperimental.Histogram, as: Histogram

  @apps [:opentelemetry_exporter, :opentelemetry, :opentelemetry_experimental]
  @handler "pinata-otel"
  @events for figure <- [:packet, :tick], kind <- [:start, :stop, :exception], do: [:pinata, figure, kind]

  @type telemetry :: %{:otlp_enabled => boolean(), :trace_ratio => float(), optional(:otlp_endpoint) => String.t()}

  @doc "Configures and starts the SDK applications from the `telemetry` settings. A failed start writes one warning."
  @spec start(telemetry()) :: :ok
  def start(telemetry) do
    _ = :telemetry.detach(@handler)
    # Only a second start in one VM (tests) finds them running.
    if List.keymember?(Application.started_applications(), :opentelemetry, 0),
      do: Enum.each(Enum.reverse(@apps), &Application.stop/1)

    # Its "Loading N CA(s)" info line has no part and would break "no log line with export off".
    _ = Application.load(:tls_certificate_check)
    :ok = Logger.put_application_level(:tls_certificate_check, :warning)
    configure(telemetry)

    case start_apps() do
      :ok ->
        attach(telemetry)

      {:error, reason} ->
        Logger.warning("Pinata: OpenTelemetry did not start (#{inspect(reason)}), nothing is exported")
    end
  end

  defp configure(%{otlp_enabled: false}) do
    # The SDK lets these variables win over the application environment.
    System.delete_env("OTEL_TRACES_EXPORTER")
    System.delete_env("OTEL_METRIC_READERS")
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry_experimental, :readers, [])
  end

  defp configure(%{otlp_enabled: true} = telemetry) do
    with {:ok, url} <- Map.fetch(telemetry, :otlp_endpoint), do: System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", url)
    Application.put_env(:opentelemetry, :traces_exporter, :otlp)

    Application.put_env(
      :opentelemetry,
      :sampler,
      {:parent_based, %{root: {:trace_id_ratio_based, telemetry.trace_ratio}}}
    )

    Application.put_env(:opentelemetry_experimental, :readers, [
      %{
        module: :otel_metric_reader,
        config: %{export_interval_ms: 60_000, exporter: {:otel_exporter_metrics_otlp, %{}}}
      }
    ])
  end

  defp start_apps do
    Enum.reduce_while(@apps, :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp attach(%{otlp_enabled: false}), do: :ok

  defp attach(%{otlp_enabled: true, trace_ratio: ratio}) do
    bounds = Pinata.Figures.boundaries_ms()

    _ =
      Histogram.create(:"pinata.packet.duration", %{
        unit: :ms,
        description: "Packet handling time",
        advisory_params: %{explicit_bucket_boundaries: bounds}
      })

    _ =
      Histogram.create(:"pinata.tick.duration", %{
        unit: :ms,
        description: "Tick duration",
        advisory_params: %{explicit_bucket_boundaries: bounds}
      })

    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)
    Logger.info("Pinata: OpenTelemetry export on, trace ratio #{ratio}")
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:pinata, figure, :start], _measurements, metadata, _config) do
    attributes = Map.delete(metadata, :telemetry_span_context)
    _ = OpentelemetryTelemetry.start_telemetry_span(:pinata, "pinata.#{figure}", metadata, %{attributes: attributes})
    :ok
  end

  def handle_event([:pinata, figure, _stop_or_exception], %{duration: duration}, metadata, _config) do
    _ = OpentelemetryTelemetry.set_current_telemetry_span(:pinata, metadata)
    :ok = OpentelemetryTelemetry.end_telemetry_span(:pinata, metadata)
    ms = System.convert_time_unit(duration, :native, :microsecond) / 1000
    record(figure, ms, metadata)
  end

  defp record(:packet, ms, %{part: part}) do
    _ = Histogram.record(:"pinata.packet.duration", ms, %{part: part})
    :ok
  end

  defp record(:tick, ms, _metadata) do
    _ = Histogram.record(:"pinata.tick.duration", ms, %{})
    :ok
  end
end
