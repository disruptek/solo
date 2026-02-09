defmodule Solo.Gateway.MetricsHandler do
  @moduledoc """
  Cowboy HTTP handler for /metrics endpoint (basic metrics export).
  """

  def init(req, state) do
    metrics = Solo.Telemetry.Prometheus.get_metrics()

    req =
      :cowboy_req.reply(
        200,
        %{"content-type" => "application/json"},
        Jason.encode!(metrics),
        req
      )

    {:ok, req, state}
  end
end
