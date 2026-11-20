import Config

# The server log: `date time [level] Part: message`, UTC (docs/user/operation.md).
config :logger, utc_log: true

config :logger, :default_formatter,
  format: "$date $time [$level] $message\n",
  metadata: [:part, :peer]
