defmodule Solo.Gateway do
  @moduledoc """
  gRPC gateway for remote agent access.

  Provides:
  - mTLS authentication (verified client certificate = tenant_id)
  - Deploy, Kill, Status, List, Watch RPCs
  - Graceful shutdown

  The gateway runs on port 50051 by default.
  """

  require Logger

  use GenServer

  @port 50051

  @doc """
  Start the Gateway GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init([]) do
    {:ok, server_pid} = start_server()
    {:ok, %{server_pid: server_pid}}
  end

  # === Private Helpers ===

  defp start_server do
    # Start the gRPC server
    case GRPC.Server.start([Solo.Gateway.Server], @port) do
      {:ok, pid, port} ->
        Logger.info("[Gateway] gRPC server started on port #{port} (requested: #{@port})")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("[Gateway] Failed to start gRPC server: #{inspect(reason)}")
        {:ok, self()}
    end
  end
end
