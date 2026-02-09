defmodule Solo.Capability.Attenuated do
  @moduledoc """
  Attenuated proxy for capability-gated resource access.

  Wraps a resource (e.g., a GenServer) and only forwards messages that
  match allowed operations. All other messages are rejected with :forbidden.

  Usage:
    {:ok, proxy_pid} = Solo.Capability.Attenuated.start_link(%{
      resource_ref: "filesystem",
      allowed_operations: [:read, :stat],
      real_pid: filesystem_server_pid,
      tenant_id: "agent_1"
    })

  The service receives `proxy_pid` instead of the real PID. Any attempt to
  call an operation not in `allowed_operations` is blocked.
  """

  use GenServer

  require Logger

  @doc """
  Start an attenuated proxy for a resource.

  Options:
  - `resource_ref`: The resource being protected (e.g., "filesystem")
  - `allowed_operations`: List of allowed operations (atoms)
  - `real_pid`: The actual resource PID
  - `tenant_id`: The tenant using this proxy
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    resource_ref = Keyword.fetch!(opts, :resource_ref)
    allowed_operations = Keyword.fetch!(opts, :allowed_operations)
    real_pid = Keyword.fetch!(opts, :real_pid)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    Logger.debug(
      "[Attenuated] Created proxy for #{resource_ref} (#{Enum.join(allowed_operations, ",")})"
    )

    {:ok,
     %{
       resource_ref: resource_ref,
       allowed_operations: allowed_operations,
       real_pid: real_pid,
       tenant_id: tenant_id
     }}
  end

  @impl GenServer
  def handle_call(message, from, state) do
    case extract_operation(message) do
      {:ok, operation} ->
        if operation in state.allowed_operations do
          # Forward to real resource
          try do
            result = GenServer.call(state.real_pid, message)
            GenServer.reply(from, result)
          rescue
            _e ->
              GenServer.reply(from, {:error, :resource_error})
          end
        else
          # Emit denial event and reject
          Solo.EventStore.emit(:capability_denied, {state.tenant_id, state.resource_ref}, %{
            reason: "operation_denied",
            operation: inspect(operation),
            allowed_operations: Enum.map(state.allowed_operations, &inspect/1),
            tenant_id: state.tenant_id
          })

          GenServer.reply(from, {:error, :forbidden})
        end

      :error ->
        # Unknown message format - reject it
        GenServer.reply(from, {:error, :forbidden})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(message, state) do
    case extract_operation(message) do
      {:ok, operation} ->
        if operation in state.allowed_operations do
          # Forward to real resource
          GenServer.cast(state.real_pid, message)
        else
          # Emit denial event
          Solo.EventStore.emit(:capability_denied, {state.tenant_id, state.resource_ref}, %{
            reason: "operation_denied",
            operation: inspect(operation),
            allowed_operations: Enum.map(state.allowed_operations, &inspect/1),
            tenant_id: state.tenant_id
          })
        end

      :error ->
        # Unknown message format - silently drop it
        nil
    end

    {:noreply, state}
  end

  # === Private Helpers ===

  defp extract_operation(message) do
    case message do
      operation when is_atom(operation) -> {:ok, operation}
      {operation, _} when is_atom(operation) -> {:ok, operation}
      {operation, _, _} when is_atom(operation) -> {:ok, operation}
      {:call, {operation, _}} when is_atom(operation) -> {:ok, operation}
      _ -> :error
    end
  end
end
