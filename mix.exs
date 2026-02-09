defmodule Solo.MixProject do
  use Mix.Project

  def project do
    [
      app: :solo,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        solo: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ],
      escript: [main_module: SoloCLI],
      # Protocol buffer compilation
      protoc_gen_elixir_version: "0.13.0"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Solo.Application, []}
    ]
  end

  defp deps do
    [
      # Persistence
      {:cubdb, "~> 2.0"},

      # gRPC (added in Phase 3)
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.13"},
      {:google_protos, "~> 0.1"},

      # Security
      {:x509, "~> 0.8"},

      # Observability
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},

      # Configuration
      {:toml, "~> 0.7"},

      # Testing
      {:stream_data, "~> 1.0", only: :test},
      {:mox, "~> 1.0", only: :test},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev}
    ]
  end
end
