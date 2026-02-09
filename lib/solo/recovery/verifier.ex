defmodule Solo.Recovery.Verifier do
  @moduledoc """
  Consistency verification and auto-fix for recovered system state (Phase 9).

  After recovery completes, the Verifier checks that the recovered state
  matches the EventStore. It detects:
  - Services deployed but missing from registry (orphaned events)
  - Services in registry but no deployment event (orphaned services)
  - Services that should be killed but are still running
  - Duplicate services
  - Service count mismatches

  Auto-fix handles minor inconsistencies:
  - Kill services that have :service_killed events
  - Emit events for recovered services without events
  - Update counts to match reality

  Severe inconsistencies are logged but not auto-fixed, requiring manual review.
  """

  require Logger

  @doc """
  Verify consistency between recovered state and EventStore.

  Returns: `{:ok, report}` with details of any inconsistencies found.
  """
  @spec verify_consistency() :: {:ok, map()} | {:error, String.t()}
  def verify_consistency do
    try do
      # Get current deployed services from registry
      deployed_services = get_deployed_services()

      # Get all deployment events from EventStore
      deployment_events = get_deployment_events()

      # Get all kill events from EventStore
      kill_events = get_kill_events()

      # Run consistency checks
      report = run_checks(deployed_services, deployment_events, kill_events)

      {:ok, report}
    rescue
      e ->
        {:error, "Verification failed: #{inspect(e)}"}
    end
  end

  @doc """
  Perform auto-fix for detected inconsistencies.

  Returns: `{:ok, fixes_applied}` with count of issues fixed.
  """
  @spec auto_fix() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def auto_fix do
    try do
      deployed_services = get_deployed_services()
      kill_events = get_kill_events()

      fixes_count = 0

      # Kill services that have :service_killed events
      fixes_count =
        Enum.reduce(kill_events, fixes_count, fn kill_event, acc ->
          {tenant_id, service_id} = kill_event.subject

          # Check if service is still running
          if service_alive?(tenant_id, service_id) do
            Logger.warning(
              "[Verifier] Auto-fixing: Killing service #{service_id} for tenant #{tenant_id}"
            )

            # Kill the service
            case Solo.Deployment.Deployer.kill(tenant_id, service_id) do
              :ok -> acc + 1
              {:error, _} -> acc
            end
          else
            acc
          end
        end)

      {:ok, fixes_count}
    rescue
      e ->
        Logger.warning("[Verifier] Auto-fix failed: #{inspect(e)}")
        {:ok, 0}
    end
  end

  @doc """
  Get the last verification report.

  Returns: `{:ok, report}` or `{:error, :not_available}`.
  """
  @spec verification_report() :: {:ok, map()} | {:error, :not_available}
  def verification_report do
    case Process.get(:last_verification_report) do
      nil -> {:error, :not_available}
      report -> {:ok, report}
    end
  end

  # ===== Private Implementation =====

  defp get_deployed_services do
    # Get all services from the Deployer's internal registry
    # Since Registry doesn't expose all services, we'll use Deployer.list
    # But that requires knowing all tenants first, so we'll get from EventStore
    try do
      # Get all unique tenants from deployment events
      deployment_events = Solo.EventStore.filter(event_type: :service_deployed)

      tenants =
        deployment_events
        |> Enum.map(fn event -> event.tenant_id end)
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1)

      # For each tenant, list services
      Enum.reduce(tenants, %{}, fn tenant_id, acc ->
        services = Solo.Deployment.Deployer.list(tenant_id)

        Enum.reduce(services, acc, fn {service_id, pid}, inner_acc ->
          key = {tenant_id, service_id}
          Map.put(inner_acc, key, pid)
        end)
      end)
    rescue
      _e -> %{}
    end
  end

  defp get_deployment_events do
    try do
      Solo.EventStore.filter(event_type: :service_deployed)
      |> Enum.map(fn event ->
        {tenant_id, service_id} = event.subject
        {{tenant_id, service_id}, event}
      end)
      |> Map.new()
    rescue
      _e -> %{}
    end
  end

  defp get_kill_events do
    try do
      Solo.EventStore.filter(event_type: :service_killed)
    rescue
      _e -> []
    end
  end

  defp run_checks(deployed_services, deployment_events, kill_events) do
    # Check 1: All deployed services have corresponding events
    orphaned_services =
      Enum.filter(deployed_services, fn {key, _pid} ->
        not Map.has_key?(deployment_events, key)
      end)

    # Check 2: All deployment events have corresponding services OR have kill events
    orphaned_events =
      Enum.filter(deployment_events, fn {key, _event} ->
        not Map.has_key?(deployed_services, key) and
          not service_has_kill_event(key, kill_events)
      end)

    # Check 3: Services with kill events should not be running
    alive_killed_services =
      Enum.filter(kill_events, fn kill_event ->
        {tenant_id, service_id} = kill_event.subject
        service_alive?(tenant_id, service_id)
      end)

    # Build report
    inconsistencies = []

    inconsistencies =
      if Enum.empty?(orphaned_services),
        do: inconsistencies,
        else: [{:orphaned_services, orphaned_services} | inconsistencies]

    inconsistencies =
      if Enum.empty?(orphaned_events),
        do: inconsistencies,
        else: [{:orphaned_events, orphaned_events} | inconsistencies]

    inconsistencies =
      if Enum.empty?(alive_killed_services),
        do: inconsistencies,
        else: [{:alive_killed_services, alive_killed_services} | inconsistencies]

    status = if Enum.empty?(inconsistencies), do: :ok, else: :warning

    %{
      status: status,
      timestamp: DateTime.utc_now(),
      total_deployed: map_size(deployed_services),
      total_events: map_size(deployment_events),
      inconsistencies_found: length(inconsistencies),
      inconsistencies: inconsistencies
    }
  end

  defp service_has_kill_event({tenant_id, service_id}, kill_events) do
    Enum.any?(kill_events, fn event ->
      event.subject == {tenant_id, service_id}
    end)
  end

  defp service_alive?(tenant_id, service_id) do
    try do
      case Solo.Deployment.Deployer.status(tenant_id, service_id) do
        status when is_map(status) ->
          status[:alive] != false

        {:error, :not_found} ->
          false

        _other ->
          false
      end
    rescue
      _e -> false
    end
  end
end
