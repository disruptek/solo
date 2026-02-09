defmodule Solo.Deployment.Deployer do
  @moduledoc """
  Core deployment and lifecycle management for services.

  The Deployer:
  1. Compiles Elixir source code
  2. Starts services under tenant supervisors
  3. Manages service lifecycle (kill, status, list)
  4. Emits events for observability
  5. Tracks deployed services (ephemeral state)

  Services are wrapped in their own Supervisor with configurable restart limits.
  """

  use GenServer

  require Logger

  # Default resource limits for services
  defp default_limits do
    %{
      max_restarts: 5,
      max_seconds: 60,
      startup_timeout_ms: 5000,
      shutdown_timeout_ms: 5000
    }
  end

  @doc """
  Start the Deployer GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Deploy a service from Elixir source code.

  Returns `{:ok, pid}` with the service process PID, or `{:error, reason}`.

  Spec fields:
  - `tenant_id` (required): The tenant deploying the service
  - `service_id` (required): Unique service identifier
  - `code` (required): Elixir source code
  - `format` (required): Must be `:elixir_source` in Phase 2
  - `restart_limits` (optional): `%{max_restarts: N, max_seconds: S}`

  Example:
  ```elixir
  Solo.Deployment.Deployer.deploy(%{
    tenant_id: "agent_1",
    service_id: "my_service",
    code: "defmodule MyService do; def start_link(_), do: {:ok, self()}; end",
    format: :elixir_source
  })
  ```
  """
  @spec deploy(map()) :: {:ok, pid()} | {:error, String.t()}
  def deploy(spec) when is_map(spec) do
    GenServer.call(__MODULE__, {:deploy, spec})
  end

  @doc """
  Kill a running service.

  Options:
  - `timeout`: Milliseconds to wait for graceful shutdown (default 5000)
  - `force`: Force kill immediately if true (default false)

  Returns `:ok` if successful, `{:error, reason}` otherwise.
  """
  @spec kill(String.t(), String.t(), Keyword.t()) :: :ok | {:error, String.t()}
  def kill(tenant_id, service_id, opts \\ []) do
    GenServer.call(__MODULE__, {:kill, tenant_id, service_id, opts})
  end

  @doc """
  Get status of a service.

  Returns a map with process info or `{:error, :not_found}`.
  """
  @spec status(String.t(), String.t()) :: map() | {:error, :not_found}
  def status(tenant_id, service_id) do
    GenServer.call(__MODULE__, {:status, tenant_id, service_id})
  end

  @doc """
  List all services for a tenant.

  Returns a list of `{service_id, pid}` tuples.
  """
  @spec list(String.t()) :: [{String.t(), pid()}]
  def list(tenant_id) do
    GenServer.call(__MODULE__, {:list, tenant_id})
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init([]) do
    Logger.info("[Deployer] Started")
    # Track active services: %{tenant_id => %{service_id => pid}}
    {:ok, %{services: %{}}}
  end

  @impl GenServer
  def handle_call({:deploy, spec}, _from, state) do
    tenant_id = Map.fetch!(spec, :tenant_id)
    service_id = Map.fetch!(spec, :service_id)
    code = Map.fetch!(spec, :code)
    format = Map.get(spec, :format, :elixir_source)
    restart_limits = Map.get(spec, :restart_limits, default_limits())

    with :ok <- validate_format(format),
         {:ok, tenant_supervisor} <- ensure_tenant_supervisor(tenant_id),
         {:ok, service_pid} <- start_service(tenant_supervisor, tenant_id, service_id, code, restart_limits) do
      # Register the service
      Solo.Registry.register(tenant_id, service_id, service_pid)

      # Track it
      tenant_services = Map.get(state.services, tenant_id, %{})
      tenant_services = Map.put(tenant_services, service_id, service_pid)
      state = %{state | services: Map.put(state.services, tenant_id, tenant_services)}

      # Emit event
      Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id
      })

      {:reply, {:ok, service_pid}, state}
    else
      {:error, reason} ->
        Solo.EventStore.emit(:service_deployment_failed, {tenant_id, service_id}, %{
          service_id: service_id,
          tenant_id: tenant_id,
          reason: reason
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:kill, tenant_id, service_id, opts}, _from, state) do
    case lookup_service(state, tenant_id, service_id) do
      {:ok, pid} ->
        timeout = Keyword.get(opts, :timeout, 5000)
        force = Keyword.get(opts, :force, false)

        Logger.info("[Deployer] Killing service #{service_id} for tenant #{tenant_id}")

         result =
           if force do
             Process.exit(pid, :kill)
             :ok
           else
             case Process.exit(pid, :shutdown) do
               true ->
                 # Wait for process to die
                 case wait_for_exit(pid, timeout) do
                   :ok -> :ok
                   :timeout -> Process.exit(pid, :kill)
                 end

               false ->
                 :ok
             end
           end

        # Emit event
        Solo.EventStore.emit(:service_killed, {tenant_id, service_id}, %{
          service_id: service_id,
          tenant_id: tenant_id
        })

        # Unregister
        Solo.Registry.unregister(tenant_id, service_id)

        # Remove from tracking
        services = Map.get(state.services, tenant_id, %{})
        services = Map.delete(services, service_id)
        state = %{state | services: Map.put(state.services, tenant_id, services)}

        {:reply, result, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:status, tenant_id, service_id}, _from, state) do
    case lookup_service(state, tenant_id, service_id) do
      {:ok, pid} ->
        info = Process.info(pid, [:memory, :message_queue_len, :reductions, :status])

        status = %{
          pid: pid,
          service_id: service_id,
          tenant_id: tenant_id,
          alive: Process.alive?(pid),
          info: info
        }

        {:reply, status, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list, tenant_id}, _from, state) do
    services =
      state[:services]
      |> Map.get(tenant_id, %{})
      |> Enum.map(fn {service_id, pid} ->
        # Filter out dead processes
        if Process.alive?(pid), do: {service_id, pid}
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, services, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Clean up dead services from tracking
    state =
      Enum.reduce(state[:services] || %{}, state, fn {tenant_id, services}, acc ->
        dead_services = Enum.filter(services, fn {_id, p} -> p == pid end)

        Enum.reduce(dead_services, acc, fn {service_id, _}, acc ->
          Logger.warning(
            "[Deployer] Service #{service_id} for tenant #{tenant_id} died: #{inspect(reason)}"
          )

          # Remove the dead service from tracking
          tenant_services = Map.get(acc.services, tenant_id, %{})
          tenant_services = Map.delete(tenant_services, service_id)
          %{acc | services: Map.put(acc.services, tenant_id, tenant_services)}
        end)
      end)

    {:noreply, state}
  end

  # === Private Helpers ===

  defp validate_format(:elixir_source), do: :ok

  defp validate_format(format) do
    {:error, "Unsupported format: #{inspect(format)}. Only :elixir_source is supported in Phase 2."}
  end

  defp ensure_tenant_supervisor(tenant_id) do
    case Solo.Tenant.Supervisor.get_or_create_tenant(tenant_id) do
      {:ok, pid} ->
        Logger.debug("[Deployer] Using tenant supervisor for #{tenant_id}: #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        {:error, "Failed to create tenant supervisor: #{inspect(reason)}"}
    end
  end

  defp start_service(tenant_supervisor, tenant_id, service_id, code, _restart_limits) do
    case Solo.Deployment.Compiler.compile(tenant_id, service_id, code) do
      {:ok, modules} ->
        module = modules |> Enum.map(&elem(&1, 0)) |> hd()

        # The user's module must have a start_link/1 function
        case ensure_start_link(module) do
          :ok ->
            spec = %{
              id: {tenant_id, service_id},
              start: {module, :start_link, [%{tenant_id: tenant_id, service_id: service_id}]},
              type: :worker,
              restart: :transient,
              shutdown: 5000
            }

            case DynamicSupervisor.start_child(tenant_supervisor, spec) do
              {:ok, pid} ->
                Logger.info("[Deployer] Started service #{service_id} for tenant #{tenant_id}: #{inspect(pid)}")
                {:ok, pid}

              {:error, reason} ->
                {:error, "Failed to start service: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Compilation failed: #{reason}"}
    end
  end

  defp ensure_start_link(module) do
    if function_exported?(module, :start_link, 1) do
      :ok
    else
      {:error,
       "Service module must export start_link/1 (got module: #{inspect(module)})"}
    end
  end

  defp lookup_service(state, tenant_id, service_id) do
    case get_in(state, [:services, tenant_id, service_id]) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end

  defp wait_for_exit(pid, timeout) when timeout > 0 do
    if Process.alive?(pid) do
      Process.sleep(10)
      wait_for_exit(pid, timeout - 10)
    else
      :ok
    end
  end

  defp wait_for_exit(_pid, _timeout) do
    :timeout
  end
end
