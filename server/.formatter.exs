[
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test,credo}/**/*.{ex,exs}"],
  import_deps: [:stream_data],
  locals_without_parens: [field: 2, bits: 1, array: 3],
  line_length: 120
]
