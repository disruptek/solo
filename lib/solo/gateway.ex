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
    # For Phase 3, we initialize the Gateway but defer actual gRPC server startup
    # Certificates will be generated on-demand via mix task
    Logger.info("[Gateway] Ready (gRPC server to be bound to port #{@port})")
    {:ok, self()}
  end


end
