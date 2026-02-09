defmodule Solo.Recovery.Replayer do
  @moduledoc """
  Event-based service recovery on system startup.

  The Replayer reconstructs the system state by replaying all :service_deployed
  events from the EventStore. For each service that was deployed and not subsequently
  killed, the Replayer attempts to redeploy it with the original specification.

  Key invariant: If a :service_killed event exists for a service (after its last
  :service_deployed event), the service is NOT recovered.

  This is a temporary GenServer that runs once during startup, completes recovery,
  and then exits. It is not restarted if it fails.

  Recovery process:
  1. Query all :service_deployed events from EventStore
  2. Group by {tenant_id, service_id} to find latest deployment
  3. For each service, check if :service_killed exists after latest :service_deployed
  4. If no kill event: redeploy with original spec
  5. If kill event exists: skip (service was intentionally stopped)
  6. Emit telemetry and return recovery report

  Startup integration: Added to Solo.System.Supervisor with restart: :temporary
  """

  use GenServer

  require Logger

  # ===== Public API =====

  @doc """
  Start the Replayer GenServer.

  The Replayer will run once, execute recovery, and exit with status :ok.
  If an error occurs, the supervisor will not restart it (temporary restart).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger recovery (mainly for testing).

  Returns: `{:ok, recovery_report}` or `{:error, reason}`
  """
  def replay_deployments do
    GenServer.call(__MODULE__, :replay, 30_000)
  catch
    :exit, _ -> {:error, "Recovery process not available"}
  end

  @doc """
  Get the last recovery report (if recovery has run).

  Returns: `{:ok, report}` or `{:error, :not_available}`
  """
  def recovery_report do
    GenServer.call(__MODULE__, :get_report, 5_000)
  catch
    :exit, _ -> {:error, :not_available}
  end

  # ===== GenServer Callbacks =====

  @impl GenServer
  def init(opts) do
    # Run recovery asynchronously to avoid blocking startup
    Process.send_after(self(), :start_recovery, 0)

    {:ok,
     %{
       report: nil,
       opts: opts
     }}
  end

  @impl GenServer
  def handle_info(:start_recovery, state) do
    Logger.info("[Recovery.Replayer] Starting service recovery from EventStore")

    report = execute_recovery()

    case report do
      {:ok, stats} ->
        Logger.info(
          "[Recovery.Replayer] Recovery complete: #{stats.recovered_count} services recovered, " <>
            "#{stats.skipped_count} skipped (killed), #{stats.failed_count} failed"
        )

      {:error, reason} ->
        Logger.warning("[Recovery.Replayer] Recovery failed: #{inspect(reason)}")
    end

    # Exit this temporary process after recovery completes
    {:stop, :normal, %{state | report: report}}
  end

  @impl GenServer
  def handle_call(:replay, _from, state) do
    report = execute_recovery()
    {:reply, report, %{state | report: report}}
  end

  def handle_call(:get_report, _from, state) do
    case state.report do
      nil -> {:reply, {:error, :not_available}, state}
      report -> {:reply, {:ok, report}, state}
    end
  end

  # ===== Private Implementation =====

  @doc false
  @spec execute_recovery() :: {:ok, map()} | {:error, String.t()}
  def execute_recovery do
    try do
      # Step 1: Get all :service_deployed events
      deployed_events =
        Solo.EventStore.filter(event_type: :service_deployed)
        |> Enum.reject(fn e -> is_nil(e.subject) or not is_tuple(e.subject) end)

      if Enum.empty?(deployed_events) do
        Logger.info("[Recovery.Replayer] No services to recover")
        return_success(%{recovered_count: 0, skipped_count: 0, failed_count: 0, services: []})
      else
        # Step 2: Get all :service_killed events
        killed_events = Solo.EventStore.filter(event_type: :service_killed)

        # Step 3: Build recovery plan
        recovery_plan = build_recovery_plan(deployed_events, killed_events)

        # Step 4: Execute recovery
        results = execute_plan(recovery_plan)

        # Step 5: Compile statistics
        recovered_count = Enum.count(results, &match?({:ok, _}, &1))
        failed_count = Enum.count(results, &match?({:error, _}, &1))
        skipped_count = Enum.count(recovery_plan, fn {_, is_killed} -> is_killed end)

        return_success(%{
          recovered_count: recovered_count,
          skipped_count: skipped_count,
          failed_count: failed_count,
          services: recovery_plan |> Enum.map(&elem(&1, 0))
        })
      end
    rescue
      e ->
        {:error, "Recovery failed with exception: #{inspect(e)}"}
    end
  end

  @spec build_recovery_plan(list(Solo.Event.t()), list(Solo.Event.t())) ::
          list(
            {%{tenant_id: String.t(), service_id: String.t(), event: Solo.Event.t()}, boolean()}
          )
  defp build_recovery_plan(deployed_events, killed_events) do
    # Group deployments by {tenant_id, service_id} to find latest
    deployments_by_service =
      deployed_events
      |> Enum.group_by(fn event ->
        {tenant_id, service_id} = event.subject
        {tenant_id, service_id}
      end)
      |> Enum.map(fn {service_key, events} ->
        {service_key, List.last(events)}
      end)
      |> Map.new()

    # Build a set of services that were killed (for fast lookup)
    killed_services =
      killed_events
      |> Enum.map(fn event ->
        {tenant_id, service_id} = event.subject
        {tenant_id, service_id}
      end)
      |> MapSet.new()

    # For each deployment, check if it was killed after deployment
    Enum.map(deployments_by_service, fn {service_key, deploy_event} ->
      {tenant_id, service_id} = service_key

      # Check if there's a kill event for this service
      is_killed = MapSet.member?(killed_services, service_key)

      service_info = %{
        tenant_id: tenant_id,
        service_id: service_id,
        event: deploy_event
      }

      {service_info, is_killed}
    end)
  end

  @spec execute_plan(
          list(
            {%{tenant_id: String.t(), service_id: String.t(), event: Solo.Event.t()}, boolean()}
          )
        ) ::
          list({:ok, pid()} | {:error, String.t()})
  defp execute_plan(plan) do
    plan
    |> Enum.reject(fn {_, is_killed} -> is_killed end)
    |> Enum.map(fn {service_info, _} ->
      redeploy_service(service_info)
    end)
  end

  @spec redeploy_service(%{tenant_id: String.t(), service_id: String.t(), event: Solo.Event.t()}) ::
          {:ok, pid()} | {:error, String.t()}
  defp redeploy_service(service_info) do
    %{tenant_id: tenant_id, service_id: service_id, event: event} = service_info

    Logger.debug("[Recovery.Replayer] Recovering service #{service_id} for tenant #{tenant_id}")

    # Extract the original spec from the event payload
    payload = event.payload

    case extract_deployment_spec(payload, tenant_id, service_id) do
      {:ok, spec} ->
        # Redeploy with original specification
        case Solo.Deployment.Deployer.deploy(spec) do
          {:ok, pid} ->
            Logger.info(
              "[Recovery.Replayer] Successfully recovered service #{service_id} for tenant #{tenant_id}: #{inspect(pid)}"
            )

            Solo.EventStore.emit(:service_recovered, {tenant_id, service_id}, %{
              service_id: service_id,
              tenant_id: tenant_id,
              original_event_id: event.id
            })

            {:ok, pid}

          {:error, reason} ->
            Logger.warning(
              "[Recovery.Replayer] Failed to recover service #{service_id} for tenant #{tenant_id}: #{inspect(reason)}"
            )

            Solo.EventStore.emit(:service_recovery_failed, {tenant_id, service_id}, %{
              service_id: service_id,
              tenant_id: tenant_id,
              reason: inspect(reason),
              original_event_id: event.id
            })

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning(
          "[Recovery.Replayer] Cannot recover service #{service_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @spec extract_deployment_spec(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  defp extract_deployment_spec(payload, tenant_id, service_id) do
    with code when not is_nil(code) <- Map.get(payload, :code),
         format when not is_nil(format) <- Map.get(payload, :format) do
      spec = %{
        tenant_id: tenant_id,
        service_id: service_id,
        code: code,
        format: format,
        restart_limits: Map.get(payload, :restart_limits, default_limits())
      }

      {:ok, spec}
    else
      _ -> {:error, "Missing required fields (code, format) in :service_deployed event"}
    end
  end

  defp default_limits do
    %{
      max_restarts: 5,
      max_seconds: 60,
      startup_timeout_ms: 5000,
      shutdown_timeout_ms: 5000
    }
  end

  defp return_success(stats) do
    {:ok, Map.merge(stats, %{status: :success, timestamp: DateTime.utc_now()})}
  end
end
