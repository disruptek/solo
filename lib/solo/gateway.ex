defmodule Solo.Gateway do
  @moduledoc """
  gRPC gateway for remote agent access.

  Provides:
  - gRPC service on port 50051 (Deploy, Kill, Status, List, Watch, Shutdown RPCs)
  - HTTP health endpoint on port 8080 (/health)
  - mTLS authentication (verified client certificate = tenant_id)

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
    # Start HTTP health check endpoint
    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/health", Solo.Gateway.HealthHandler, []},
           {"/metrics", Solo.Gateway.MetricsHandler, []},
           {"/:_", Solo.Gateway.NotFoundHandler, []}
         ]}
      ])

    case :cowboy.start_clear(:http, [port: @http_port], %{env: [dispatch: dispatch]}) do
      {:ok, pid} ->
        Logger.info("[Gateway] HTTP health endpoint started on port #{@http_port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[Gateway] Failed to start HTTP server: #{inspect(reason)}")
        {:ok, self()}
    end
  end
end
