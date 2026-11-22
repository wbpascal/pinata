defmodule Pinata.OtelTest do
  # Restarts the OpenTelemetry applications and changes OTEL_* variables of the test VM.
  use ExUnit.Case, async: false

  @variables ~w(OTEL_TRACES_EXPORTER OTEL_METRIC_READERS OTEL_EXPORTER_OTLP_ENDPOINT)
  @apps [:opentelemetry, :opentelemetry_experimental, :opentelemetry_exporter]

  setup do
    saved = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      :ok = Pinata.Otel.start(%{otlp_enabled: false, trace_ratio: 0.01})
    end)
  end

  defp listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    {listener, port}
  end

  defp emit do
    metadata = %{part: "Login", opcode: "Test"}
    :ok = :telemetry.span([:pinata, :packet], metadata, fn -> {:ok, metadata} end)
    _ = :otel_tracer_provider.force_flush()
    :ok
  end

  defp attached? do
    Enum.any?(:telemetry.list_handlers([:pinata, :packet]), &(&1.id == "pinata-otel"))
  end

  defp started?, do: Enum.all?(@apps, &List.keymember?(Application.started_applications(), &1, 0))

  test "export off: no connection attempt, whatever the environment says" do
    {listener, port} = listener()
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OTEL_TRACES_EXPORTER", "otlp")
    log = TestLog.capture(fn -> :ok = Pinata.Otel.start(%{otlp_enabled: false, trace_ratio: 1.0}) end)
    emit()
    assert {:error, :timeout} = :gen_tcp.accept(listener, 2_000)
    assert System.get_env("OTEL_TRACES_EXPORTER") == nil
    refute attached?()
    refute log =~ "OTLP"
    refute log =~ "CA(s)"
    refute log =~ "Pinata:"
    assert started?()
  end

  test "export on: connects to telemetry.otlp_endpoint, which wins over the variable" do
    {listener, port} = listener()
    # nothing listens there
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:1")
    settings = %{otlp_enabled: true, otlp_endpoint: "http://127.0.0.1:#{port}", trace_ratio: 1.0}
    log = TestLog.capture(fn -> :ok = Pinata.Otel.start(settings) end)
    emit()
    assert {:ok, _socket} = :gen_tcp.accept(listener, 10_000)
    assert log =~ "[info] Pinata: OpenTelemetry export on, trace ratio 1.0"
    assert attached?()
    assert started?()
  end
end
