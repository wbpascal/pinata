# Telemetry events in the code, OpenTelemetry attached by a setting

Server code reports what it measures only as `:telemetry` events and writes the server log only through `Logger`; it never calls the OpenTelemetry API. The release ships the OpenTelemetry trace libraries (stable) and the metrics SDK (experimental, 0.x), off by default and turned on by the setting `telemetry.otlp_enabled`. The server log is not exported over OpenTelemetry. The two capacity figures are counted in fixed-bucket histograms of our own and read with a release command, so a load run never depends on the experimental parts.

We chose this because an administrator should get traces and metrics from the published release without building their own, while only traces are stable on the BEAM (research: issue #86). The alternatives were to ship no OpenTelemetry library and leave attaching it to the administrator (rejected: it makes the feature unavailable to users of the release archive), and to call the OpenTelemetry API directly from server code (rejected: it ties every measuring point to a 0.x metrics API). Exporting the server log was left out because the log handler of `opentelemetry_experimental` 0.6.0 has an unbounded queue, which would leak memory on a game server whose collector goes away.

## Consequences

- Where a duration is measured, the code emits a `:telemetry` span (`start` / `stop`). One event pair feeds the capacity figure, the OpenTelemetry metric and the trace.
- The handlers that turn events into OpenTelemetry metrics and spans are attached only when `telemetry.otlp_enabled` is true. When it is false the exporters are set to none: no connection attempt, no server log line.
- Spans are sampled by a ratio (`telemetry.trace_ratio`); metrics and the capacity figures count every event.
- An upgrade of the experimental metrics SDK may break the metrics handler; it is the only code that names that API.
- Exporting the server log is added as a `logger` handler by configuration once the upstream handler bounds its queue. No server code changes for it.
