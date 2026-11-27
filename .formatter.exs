[
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test,credo}/**/*.{ex,exs}", "priv/**/*.exs"],
  import_deps: [:stream_data, :ecto, :ecto_sql],
  locals_without_parens: [field: 2, bits: 1, array: 3],
  line_length: 120
]
