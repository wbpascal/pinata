%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        # probe files break the rules on purpose (test/credo_checks_test.exs, test/boundary_test.exs)
        excluded: ["test/probes/"]
      },
      requires: ["./credo/checks/**/*.ex"],
      checks: %{
        extra: [
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MixEnv, []},
          {Fiesta.Credo.NoNilReturn, []},
          {Fiesta.Credo.NoNamedTable, []},
          {Fiesta.Credo.DirectTimeOrRandom, []}
        ]
      }
    }
  ]
}
