defmodule Solo.Gateway.REST.Router do
  @moduledoc """
  Cowboy router configuration for REST API endpoints.

  Routes HTTP requests to appropriate handler modules:
  - POST /services - Deploy service
  - GET /services - List services
  - GET /services/{service_id} - Get service status
  - DELETE /services/{service_id} - Kill service
  - GET /events - Stream events (Server-Sent Events)
  - GET /health - Health check
  """

  @doc """
  Compile Cowboy router with REST API routes.

  Returns a compiled dispatch configuration suitable for :cowboy.start_clear/3
  """
  def compile do
    :cowboy_router.compile([
      {:_, routes()}
    ])
  end

  @doc """
  REST API route definitions
  """
  def routes do
    [
      # Service Management
      {"/services", Solo.Gateway.REST.ServicesHandler, []},
      {"/services/:service_id", Solo.Gateway.REST.ServiceHandler, []},

      # Secrets Management
      {"/secrets", Solo.Gateway.REST.SecretsHandler, []},
      {"/secrets/:key", Solo.Gateway.REST.SecretsHandler, []},

      # Events Streaming
      {"/events", Solo.Gateway.REST.EventsHandler, []},

      # Logs Streaming
      {"/logs", Solo.Gateway.REST.LogsHandler, []},

      # Health Check
      {"/health", Solo.Gateway.HealthHandler, []},

      # Metrics
      {"/metrics", Solo.Gateway.MetricsHandler, []},

      # Catch-all 404
      {"/:_", Solo.Gateway.NotFoundHandler, []}
    ]
  end
end
