# State of the OpenTelemetry libraries for Erlang and Elixir

Research for [#86](https://github.com/wbpascal/pinata/issues/86), input to
[#87](https://github.com/wbpascal/pinata/issues/87). Checked on 2026-11-21 against Elixir 1.20.5 on
OTP 29.

Evidence marks: plain statement = read in the cited primary source. *(measured)* = run locally in a
scratch Mix project on Elixir 1.20.5 / OTP 29, Apple silicon, 10 schedulers (method in the last
section). *(inferred)* = my conclusion.

## Answer in short

| Signal | Official library (hex) | Status | Usable today? |
|---|---|---|---|
| Traces | `opentelemetry_api` 1.5.0, `opentelemetry` 1.7.0, `opentelemetry_exporter` 1.11.0 | **Stable** | Yes |
| Metrics | `opentelemetry_api_experimental` 0.6.0, `opentelemetry_experimental` 0.6.0 | **Development** (experimental, 0.x) | Works, API may break; explicit-bucket histograms only |
| Logs | `otel_log_handler` inside `opentelemetry_experimental` 0.6.0 | **Development**, "documentation TBA" | Works only with a non-default exporter setting; queue is unbounded |

- Only traces are stable. Metrics and logs sit in a package named "experimental" that went 30
  months without a release (0.5.1 in March 2024, 0.6.0 in September 2026).
- Nothing official turns a `:telemetry` event into an OTel **metric**. The official bridge
  (`opentelemetry_telemetry`) makes **spans** only. For metrics you write a handler that calls the
  metrics API, or use a `Telemetry.Metrics` reporter (`peep` for Prometheus, the unofficial
  `otel_metric_exporter` for OTLP).
- Logs attach as an OTP `logger` handler, which Elixir's `Logger` uses directly.
- Cost is small: about 0.17 µs for a `:telemetry` event recorded into an SDK histogram, about
  2.5 µs per sampled span, about 5 MB and 37 processes at idle with everything loaded and exporters
  off *(measured)*.
- It can be left out without code changes. If the server code only emits `:telemetry` events and
  `Logger` calls, the OTel packages are pure configuration: exporters set to none (or the
  applications not started) gives a silent offline start *(measured)*.

## Sources of the status

- opentelemetry.io status table: Erlang/Elixir is `traces: stable`, `metrics: development`,
  `logs: development`
  ([data/instrumentation.yaml](https://github.com/open-telemetry/opentelemetry.io/blob/main/data/instrumentation.yaml),
  rendered at <https://opentelemetry.io/docs/languages/erlang/>).
- The metrics and logs code lives in `apps/opentelemetry_experimental`, whose README opens with
  "Signals still in experimental status in the Erlang/Elixir SDK" and whose application description
  is "Implementation of unstable OpenTelemetry signals"
  ([README](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry_experimental/README.md),
  [app.src](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry_experimental/src/opentelemetry_experimental.app.src)).
- Logs in the official docs, in full: "The logs API ... is currently unstable, documentation TBA"
  ([instrumentation.md](https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/docs/languages/erlang/instrumentation.md)).
- Release dates and versions: hex.pm API (`https://hex.pm/api/packages/<name>`).
  `opentelemetry_experimental`: 0.5.1 on 2024-03-19, 0.6.0 on 2026-09-15. Upstream issue
  [#1006](https://github.com/open-telemetry/opentelemetry-erlang/issues/1006) says that before
  0.6.0 no published package combination could export OTLP logs at all.
- Spec compliance matrix, Erlang column
  ([spec-compliance-matrix.md](https://github.com/open-telemetry/opentelemetry-specification/blob/main/spec-compliance-matrix.md)),
  my tally: traces 51 yes / 2 no; metrics 68 yes / 17 no (missing among others: synchronous Gauge,
  cardinality limits, view wildcards); **logs: all 18 rows blank**; exporters 14 yes / 37 no (no
  Prometheus exporter, no gzip, no retry with backoff).

## OTP 29 and Elixir 1.20

- Upstream CI tests the Erlang side on OTP 29.0, 28.1 and 27.2
  ([erlang.yml](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/.github/workflows/erlang.yml)).
  The Elixir test jobs run on Elixir 1.18.1 and 1.14.5 with OTP 27; Elixir 1.20 appears only in a
  format/lint job, on OTP 27
  ([elixir.yml](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/.github/workflows/elixir.yml)).
  The documented minimum is Erlang 23 and Elixir 1.13.
- *(measured)* All packages in the table, plus `peep` 6.0.0 and `otel_metric_exporter` 0.4.4,
  compile on Elixir 1.20.5 / OTP 29 and ran the probes below. The official packages compiled
  without warnings; `otel_metric_exporter` gave three warnings (unused `require`, redundant clause).
  This is a smoke test, not their test suites.

## Traces

- API and SDK are separate: "When only the API is available at runtime a no-op Tracer is used and
  no Traces are created"
  ([API README](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry_api/README.md)).
- Export: OTLP over HTTP/protobuf or gRPC through `opentelemetry_exporter`. Finished spans go into
  ETS; the batch processor exports every 5 s or at 2048 queued spans
  ([SDK README](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry/README.md)).
- Off switches: `config :opentelemetry, traces_exporter: :none`, or `OTEL_SDK_DISABLED=true`,
  which skips starting the tracer provider
  ([opentelemetry_app.erl](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry/src/opentelemetry_app.erl)).
  Sampling is configurable (`OTEL_TRACES_SAMPLER`, default `parentbased_always_on`).
- From `:telemetry`: `opentelemetry_telemetry` 1.1.2 (official contrib) starts and ends spans from
  `:telemetry` span events. Its README says it is meant for instrumentation libraries, not for
  direct use in application code
  ([README](https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/utilities/opentelemetry_telemetry/README.md)).
  Ready-made instrumentation exists for Ecto (`opentelemetry_ecto`), not for Thousand Island.

## Metrics

- Instruments: counter, up-down counter, histogram, and the three observable (asynchronous) kinds.
  Aggregations: sum, last value, drop, and **explicit bucket histogram only**; there is no
  exponential histogram
  ([experimental README](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry_experimental/README.md)).
- Readers: periodic (push, `export_interval_ms`) or pull. Exporters shipped: OTLP
  (`otel_exporter_metrics_otlp`) and console. No Prometheus exporter in the official packages.
- Nothing is exported until a reader is configured: the default is `readers: []`
  ([otel_configuration.erl](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry/src/otel_configuration.erl)).
- **Consequence for the two load-run figures** *(inferred)*: a 99th percentile comes out of bucket
  counts, so it is an estimate between two boundaries. The default boundaries (0, 5, 10, 25, 50,
  75, 100, 250 ... 10000) happen to include 50 and 100, so with durations recorded in milliseconds
  "p99 under 50 ms" and "p99 under 100 ms" can be decided exactly as "at least 99 % of the count is
  in buckets up to that boundary". The same holds for `peep` and `otel_metric_exporter`, which also
  use fixed buckets.

### From `:telemetry` events to metrics

| Route | What it is | OTel compatible how | Notes |
|---|---|---|---|
| Own handler calling `OpenTelemetryAPIExperimental.Histogram.record/3` | A few lines per event, official SDK | OTLP push | Experimental API. *(measured)* five events through `:telemetry` came out of a reader as one histogram data point with the right bucket counts, min, max and sum |
| [`otel_metric_exporter`](https://github.com/electric-sql/elixir-otel-metric-exporter) 0.4.4 | `Telemetry.Metrics` reporter that pushes OTLP | OTLP push (HTTP) | Calls itself "unofficial", does not use `opentelemetry_api`, no exponential histogram or summary. Pulls `finch`, `mint`, `protobuf`, `retry`. 90 k downloads. Also ships its own Logger handler for OTLP logs |
| [`peep`](https://github.com/rkallos/peep) 6.0.0 | `Telemetry.Metrics` reporter with ETS histograms | Prometheus text (scraped by an OTel Collector) or StatsD | No OTLP. No network at all unless something scrapes; needs an HTTP endpoint to serve the text (`plug` is optional). 3 M downloads |
| `telemetry_metrics_prometheus_core` 1.2.1 | Same idea, older | Prometheus text | Last release March 2024 |

`Telemetry.Metrics` (`telemetry_metrics` 1.2.0) only defines metrics; a reporter does the work.
`:telemetry` handlers run synchronously in the process that emits the event
([telemetry README](https://github.com/beam-telemetry/telemetry/blob/main/README.md)), so the cost
below is paid by the connection process or the tick.

## Logs

- `otel_log_handler` is an OTP `logger` handler: a `gen_statem` that collects events and exports a
  batch every 5 s (`scheduled_delay_ms`)
  ([otel_log_handler.erl](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry_experimental/src/otel_log_handler.erl)).
- Attaching to `Logger`: Elixir's `Logger` sits on OTP `logger`, so the handler is added with
  `config :pinata, :logger, [{:handler, :otel, :otel_log_handler, %{...}}]` plus
  `Logger.add_handlers(:pinata)`, or `:logger.add_handler/3`
  ([Logger docs, "Erlang/OTP handlers"](https://hexdocs.pm/logger/Logger.html#module-erlang-otp-handlers)).
  The existing console handler (the Server log) is untouched; this is a second, parallel handler.
  *(measured)* `:logger.add_handler(:otel, :otel_log_handler, ...)` returned `:ok` and received
  `Logger` events.
- Trace correlation: the SDK puts `otel_trace_id` and `otel_span_id` into the logger metadata of
  the process that has an active span *(measured: visible in the event the handler received)*.
- Problems found in 0.6.0:
  - **The default exporter is wrong.** Without an `exporter` key the handler uses
    `{opentelemetry_exporter, #{protocol => grpc}}`, the traces exporter; every export then fails
    with `bad argument in ets:first/1` and logs a warning of about 110 lines, each interval, and
    that warning is itself fed back into the handler *(measured; the default is visible in the
    source above)*. With `exporter: {:otel_exporter_logs_otlp, %{}}` it exports properly.
  - **The queue is unbounded.** `max_queue_size` and `exporting_timeout_ms` are read but not
    applied, so a stalled collector grows the handler's memory without limit. Stated in upstream PR
    [#1044](https://github.com/open-telemetry/opentelemetry-erlang/pull/1044) (closed without
    merge); the larger rework [#671](https://github.com/open-telemetry/opentelemetry-erlang/pull/671)
    has been open since December 2023.
  - The record timestamp is the export time, not the time of the event (open issue
    [#1048](https://github.com/open-telemetry/opentelemetry-erlang/issues/1048)).
  - `OTEL_SDK_DISABLED=true` does not stop the log handler; it kept exporting *(measured)*.
- Alternative without any OTel log library *(inferred)*: write the Server log as structured lines
  to stdout or a file and let an OTel Collector's filelog receiver turn it into OTLP logs. That
  keeps the server free of the experimental handler.

## Cost

No per-event or idle cost is documented by the OpenTelemetry Erlang project; I found no benchmark
figures in its READMEs or docs. Everything below is *(measured)*, single process, exporters off, so
it is the recording path only.

Idle, after application start, nothing emitted:

| Layer added | Processes | ETS tables | Memory |
|---|---|---|---|
| `opentelemetry_api` | 0 | 0 | ~0 |
| `opentelemetry_exporter` and its dependencies (grpcbox, chatterbox, gproc, tls_certificate_check ...) | +16 | +4 | +3.3 MB |
| `opentelemetry` SDK, traces | +12 | +3 | +1.2 MB |
| `opentelemetry_experimental`, metrics | +8 | +5 | +0.3 MB |
| `otel_log_handler` | +1 | 0 | ~0 |
| With `OTEL_SDK_DISABLED=true`: SDK +3 processes, experimental +5, exporter dependencies unchanged | | | |

`tls_certificate_check` also logs "Loading 155 CA(s) from :otp store" at info level on start.

Per event (median of 5 runs of 200 000 calls):

| Operation | Time |
|---|---|
| `:telemetry.execute`, no handler attached | 44 ns |
| `:telemetry.execute`, one no-op handler | 82 ns |
| API only, SDK not started: `Tracer.with_span` | 262 ns |
| API only, SDK not started: `Histogram.record` | 142 ns |
| SDK `Histogram.record` | 133 ns |
| `:telemetry.execute` → handler → SDK `Histogram.record` | 170 ns |
| `:telemetry.execute` → `peep` distribution | 268 ns |
| `:telemetry.execute` → `otel_metric_exporter` distribution | 807 ns |
| SDK `Tracer.with_span`, sampled, exporter none | 2500 ns |
| `Logger.info` with no handler | 674 ns |
| `Logger.info` with only `otel_log_handler` | 1448 ns |

*(inferred)* At the World scenario's order of magnitude (2500 players, some tens of thousands of
packets per second at most) a histogram per packet costs a few milliseconds of CPU per second in
total. A span per packet is about 15 times dearer and fills the 2048-span batch queue quickly; it
would need sampling.

## Leaving it out of a single-node offline start

All *(measured)* with nothing listening on the OTLP ports:

- **Exporters off** (`traces_exporter: :none`, no `readers`, no log handler or `exporter: :none`):
  starts, prints nothing beyond the CA line above, makes no connection attempt. Cost is the idle
  table above.
- **Library defaults with no collector**: the node stays up. Trace and metric exports to
  `localhost:4318` fail and each failure logs `client error exporting {:failed_connect, ...}` at
  info level, once per export interval per signal. Noisy, not fatal.
- **Applications not started at all** (dependency present, API calls in the code): the API calls
  are no-ops, see the two "API only" rows.
- **No OTel calls in the server code**: if the server emits only `:telemetry` events and `Logger`
  calls, every OTel piece is attached from outside (a handler module, a reader in config, a logger
  handler in config). Whether OTel is on is then a configuration difference between the offline
  start and a deployed one, with no code change. This is the route that fits "single-node, offline,
  lightweight" best *(inferred)*.

Dependency weight if added to `server/mix.exs`: the server already locks `telemetry`, `jason` and
`nimble_options`. Official traces + metrics + logs over OTLP add 12 packages (`opentelemetry_api`,
`opentelemetry`, `opentelemetry_exporter`, the two experimental ones, `grpcbox`, `chatterbox`,
`hpack`, `ctx`, `acceptor_pool`, `gproc`, `tls_certificate_check`, `ssl_verify_fun`); `grpcbox`
comes along even when only HTTP is used. `peep` adds 2 (`peep`, `telemetry_metrics`).

## Not verified

- No export to a real OpenTelemetry Collector was run: OTLP payload correctness on OTP 29 is not
  checked, only the failure path with nothing listening and an in-process test exporter.
- The upstream test suites were not run on Elixir 1.20 / OTP 29; upstream CI covers OTP 29 for
  Erlang only.
- Cost figures are from one machine, one process, no contention. Concurrent writers to the same
  histogram (many connection processes) were not measured, nor was export cost (encoding, HTTP).
- Memory growth of the unbounded log queue and of high-cardinality metric attributes was not
  measured.
- No roadmap or date for stable metrics or logs was found; the only tracking issue found
  ([#412 "Stable metrics sdk"](https://github.com/open-telemetry/opentelemetry-erlang/issues/412))
  is closed. Whether the fixes on `main` after 0.6.0 change any of the above was not checked,
  except that the wrong default log exporter is still on `main`.
- `peep`'s and `otel_metric_exporter`'s own export paths (Prometheus text, OTLP push) were not
  exercised, only their recording path.
- Release behaviour was not tested. The upstream README requires, in a release,
  `applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]` and
  `opentelemetry_exporter` listed before the other `opentelemetry` dependencies, so that the
  exporter's dependencies start first and an SDK crash does not stop the node
  ([README](https://github.com/open-telemetry/opentelemetry-erlang/blob/main/README.md)). The
  probes started the applications by hand in that order.

## Method of the measurements

Scratch Mix project (not in this repository) with `telemetry` 1.4.3, `telemetry_metrics` 1.2.0,
`opentelemetry_api` 1.5.0, `opentelemetry` 1.7.0, `opentelemetry_exporter` 1.11.0,
`opentelemetry_api_experimental` 0.6.0, `opentelemetry_experimental` 0.6.0, `peep` 6.0.0,
`otel_metric_exporter` 0.4.4, all `runtime: false` so that each script starts exactly the
applications it measures with `Application.ensure_all_started/1`.

- Idle: `length(Process.list())`, `length(:ets.all())` and `:erlang.memory(:total)` after a garbage
  collection, before and 500 ms after starting each layer.
- Per event: `:timer.tc` around 200 000 calls in one process, five runs, median; `mix run` in the
  `dev` environment.
- Offline behaviour: one span, one histogram record and one `Logger.warning`, then 7 s of waiting,
  in three configurations (exporters off; defaults; `OTEL_SDK_DISABLED=true`).
- Metric round trip: reader with `export_interval_ms: 500` and the SDK's `otel_metric_exporter_pid`
  test exporter, five `:telemetry` events with durations 3, 7, 7, 60, 400.
