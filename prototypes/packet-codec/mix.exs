defmodule PacketCodecProto.MixProject do
  use Mix.Project

  # PROTOTYPE for issue 14 (throwaway, not for master). See README.md.
  def project do
    [
      app: :packet_codec_proto,
      version: "0.0.0",
      elixir: "~> 1.20",
      elixirc_paths: if(System.get_env("PROBES"), do: ["lib", "probes"], else: ["lib"]),
      deps: [{:dialyxir, "~> 1.4", only: :dev, runtime: false}],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
