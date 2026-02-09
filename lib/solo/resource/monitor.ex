defmodule Solo.Resource.Monitor do
  @moduledoc """
  Monitors resource usage of deployed services.

  Periodically checks:
  - Memory usage
  - Message queue length
  - Process count
  - Reductions (CPU work)

  Takes configured action when limits are exceeded:
  - `:kill` - terminates the service
  - `:throttle` - applies backpressure
  - `:warn` - emits event and logs warning

  Monitors are started automatically when services are deployed.
  """

  use GenServer

  require Logger

  @doc """
  Start a resource monitor for a service.

  Options:
  - `tenant_id`: The tenant owning the service
  - `service_id`: The service being monitored
  - `pid`: The service process PID
  - `limits`: Solo.Resource.Limits configuration
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    service_id = Keyword.fetch!(opts, :service_id)
    pid = Keyword.fetch!(opts, :pid)
    limits = Keyword.get(opts, :limits, Solo.Resource.Limits.new())

    Logger.debug("[Resource.Monitor] Started for #{tenant_id}/#{service_id}")

    # Schedule first check
    schedule_check(limits.check_interval_ms)

    {:ok,
     %{
       tenant_id: tenant_id,
       service_id: service_id,
       pid: pid,
       limits: limits,
       history: []
     }}
  end

  @impl GenServer
  def handle_info(:check, state) do
    state = check_resources(state)
    schedule_check(state.limits.check_interval_ms)
    {:noreply, state}
  end

  # === Private Helpers ===

  defp check_resources(state) do
    %{pid: pid, limits: limits, tenant_id: tenant_id, service_id: service_id} = state

    if not Process.alive?(pid) do
      Logger.debug(
        "[Resource.Monitor] Service #{service_id} for #{tenant_id} is no longer alive"
      )

      state
    else
      # Get process info
      info = Process.info(pid, [:memory, :message_queue_len, :reductions, :status])

      if info do
        check_memory(state, info) |> check_mailbox(info) |> record_history(info)
      else
        state
      end
    end
  end

  defp check_memory(state, info) do
    %{limits: limits, tenant_id: tenant_id, service_id: service_id, pid: pid} = state

    memory = Keyword.get(info, :memory, 0)
    limit = limits.max_memory_bytes
    warning_threshold = Solo.Resource.Limits.memory_warning_bytes(limits)

    cond do
      memory > limit ->
        Logger.warning(
          "[Resource.Monitor] Service #{service_id}/#{tenant_id} exceeds memory limit: #{memory} > #{limit}"
        )

        Solo.EventStore.emit(:resource_violation, {tenant_id, service_id}, %{
          resource: :memory,
          limit: limit,
          current: memory,
          action: limits.memory_action,
          tenant_id: tenant_id,
          service_id: service_id
        })

        if limits.memory_action == :kill do
          Process.exit(pid, :kill)
        end

        state

      memory > warning_threshold ->
        Logger.warning(
          "[Resource.Monitor] Service #{service_id}/#{tenant_id} approaching memory limit: #{memory} > #{warning_threshold}"
        )

        Solo.EventStore.emit(:resource_violation, {tenant_id, service_id}, %{
          resource: :memory,
          limit: limit,
          current: memory,
          action: :warn,
          tenant_id: tenant_id,
          service_id: service_id
        })

        state

      true ->
        state
    end
  end

  defp check_mailbox(state, info) do
    %{limits: limits, tenant_id: tenant_id, service_id: service_id} = state

    queue_len = Keyword.get(info, :message_queue_len, 0)
    limit = limits.max_message_queue_len

    if queue_len > limit do
      Logger.warning(
        "[Resource.Monitor] Service #{service_id}/#{tenant_id} mailbox overflow: #{queue_len} > #{limit}"
      )

      Solo.EventStore.emit(:resource_violation, {tenant_id, service_id}, %{
        resource: :mailbox,
        limit: limit,
        current: queue_len,
        action: limits.mailbox_action,
        tenant_id: tenant_id,
        service_id: service_id
      })

      # Throttling would be applied at the gateway level
      state
    else
      state
    end
  end

  defp record_history(state, info) do
    memory = Keyword.get(info, :memory, 0)
    queue_len = Keyword.get(info, :message_queue_len, 0)
    reductions = Keyword.get(info, :reductions, 0)

    reading = %{
      timestamp: System.system_time(:millisecond),
      memory: memory,
      queue_len: queue_len,
      reductions: reductions
    }

    # Keep last 60 readings
    history = [reading | state.history] |> Enum.take(60)

    %{state | history: history}
  end

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end
end
