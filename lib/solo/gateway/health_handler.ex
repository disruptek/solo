defmodule Solo.Gateway.HealthHandler do
  @moduledoc """
  Cowboy HTTP handler for /health endpoint.
  """

  def init(req, state) do
    health_status = Solo.Telemetry.Prometheus.health_status()

    req =
      :cowboy_req.reply(
        200,
        %{"content-type" => "application/json"},
        Jason.encode!(health_status),
        req
      )

    {:ok, req, state}
  end
end
