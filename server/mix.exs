defmodule Pinata.MixProject do
  use Mix.Project

  def project do
    [
      app: :pinata,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(),
      test_ignore_filters: [&String.starts_with?(&1, "test/probes/")],
      compilers: [:boundary] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        flags: [:unmatched_returns, :extra_return, :missing_return],
        plt_local_path: "plts",
        plt_core_path: "plts",
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Pinata.Application, []}
    ]
  end

  # PINATA_BOUNDARY_PROBE adds a file with a forbidden part-to-part reference (test/boundary_test.exs).
  defp elixirc_paths do
    if System.get_env("PINATA_BOUNDARY_PROBE"), do: ["lib", "test/probes/boundary"], else: ["lib"]
  end

  defp deps do
    [
      {:boundary, "~> 0.12.0", runtime: false},
      {:toml, "~> 0.7"},
      {:thousand_island, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:libcluster, "~> 3.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"},
      {:ecto_sqlite3, "~> 0.26.0"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["test --no-start"],
      check: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "hex.audit",
        "compile --warnings-as-errors",
        "xref graph --label compile-connected --fail-above 0",
        "credo",
        "dialyzer",
        "test --warnings-as-errors"
      ]
    ]
  end
end
