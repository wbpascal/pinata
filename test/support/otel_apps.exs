# Prints the started OpenTelemetry applications, sorted. The CI job otel-smoke greps the line; test/workflow_test.exs
# loads this file (AGENTS.md, "CI jobs").
apps = [:opentelemetry, :opentelemetry_experimental, :opentelemetry_exporter]
IO.puts(inspect(Enum.sort(for {app, _, _} <- Application.started_applications(), app in apps, do: app)))
