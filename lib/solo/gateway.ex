defmodule Solo.Gateway do
  @moduledoc """
  Dual-protocol gateway for remote agent access.

  Provides:
  - gRPC service on port 50051 (Deploy, Kill, Status, List, Watch, Shutdown RPCs)
  - REST API on port 8080 (HTTP/JSON endpoints for service management and monitoring)
  - mTLS authentication (verified client certificate = tenant_id)

  REST API includes:
  - POST /services - Deploy service
  - GET /services - List services
  - GET /services/{id} - Get service status
  - DELETE /services/{id} - Kill service
  - GET /events - Stream events (Server-Sent Events)
  - GET /health - Health check

  The gateway manages both gRPC and HTTP servers.
  """

  require Logger

  use GenServer

  @grpc_port 50051
  @http_port 8080

  @doc """
  Start the Gateway GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init([]) do
    {:ok, grpc_pid} = start_grpc_server()
    {:ok, http_pid} = start_http_server()
    {:ok, %{grpc_pid: grpc_pid, http_pid: http_pid}}
  end

  # === Private Helpers ===

  defp start_grpc_server do
    # Start the gRPC server
    case GRPC.Server.start([Solo.Gateway.Server], @grpc_port) do
      {:ok, pid, port} ->
        Logger.info("[Gateway] gRPC server started on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("[Gateway] Failed to start gRPC server: #{inspect(reason)}")
        {:ok, self()}
    end
  end

  defp start_http_server do
    # Start HTTP REST API endpoints
    dispatch = Solo.Gateway.REST.Router.compile()

    case :cowboy.start_clear(:http, [port: @http_port], %{env: [dispatch: dispatch]}) do
      {:ok, pid} ->
        Logger.info("[Gateway] REST API started on port #{@http_port}")
        Logger.info("[Gateway] Available endpoints:")
        Logger.info("[Gateway]   POST /services - Deploy service")
        Logger.info("[Gateway]   GET /services - List services")
        Logger.info("[Gateway]   GET /services/{id} - Get service status")
        Logger.info("[Gateway]   DELETE /services/{id} - Kill service")
        Logger.info("[Gateway]   GET /events - Stream events (SSE)")
        Logger.info("[Gateway]   GET /health - Health check")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[Gateway] Failed to start HTTP server: #{inspect(reason)}")
        {:ok, self()}
    end
  end
end
