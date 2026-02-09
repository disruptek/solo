defmodule Solo.ServiceRegistry do
  @moduledoc """
  Service Registry for discovery and metadata management.

  Tracks service registrations with:
  - Service name and ID mapping
  - Metadata (tags, version, environment)
  - TTL-based expiration
  - Query and filtering capabilities

  This complements the basic Registry by adding discovery features.
  """

  use GenServer

  require Logger

  @name __MODULE__

  # ===  Public API ===

  @doc """
  Start the Service Registry.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  @doc """
  Register a service with metadata.
  """
  def register(tenant_id, service_id, service_name, version, metadata, ttl_seconds)
      when is_binary(tenant_id) and is_binary(service_id) and is_binary(service_name) do
    GenServer.call(@name, {
      :register,
      tenant_id,
      service_id,
      service_name,
      version,
      metadata || %{},
      ttl_seconds
    })
  end

  @doc """
  Discover services by name with optional filters.
  """
  def discover(tenant_id, service_name, filters \\ %{})
      when is_binary(tenant_id) and is_binary(service_name) do
    GenServer.call(@name, {:discover, tenant_id, service_name, filters})
  end

  @doc """
  Get all services for a tenant.
  """
  def list_services(tenant_id, service_name \\ nil) when is_binary(tenant_id) do
    GenServer.call(@name, {:list, tenant_id, service_name})
  end

  @doc """
  Unregister a service.
  """
  def unregister(tenant_id, service_id)
      when is_binary(tenant_id) and is_binary(service_id) do
    GenServer.call(@name, {:unregister, tenant_id, service_id})
  end

  @doc """
  Get metadata for a service.
  """
  def get_metadata(tenant_id, service_id)
      when is_binary(tenant_id) and is_binary(service_id) do
    GenServer.call(@name, {:get_metadata, tenant_id, service_id})
  end

  @doc """
  Get service handle (registration ID).
  """
  def get_handle(tenant_id, service_id)
      when is_binary(tenant_id) and is_binary(service_id) do
    GenServer.call(@name, {:get_handle, tenant_id, service_id})
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init([]) do
    Logger.info("[ServiceRegistry] Started")

    # Start a periodic cleanup task for expired registrations
    Process.send_after(self(), :cleanup_expired, 60000)

    {:ok,
     %{
       # tenant_id -> service_id -> registration
       registrations: %{},
       # service_name -> [registrations]
       name_index: %{},
       # handle -> {tenant_id, service_id}
       handle_map: %{}
     }}
  end

  @impl GenServer
  def handle_call(
        {:register, tenant_id, service_id, service_name, version, metadata, ttl_seconds},
        _from,
        state
      ) do
    handle = generate_handle()
    now = System.os_time(:millisecond)
    expires_at = if ttl_seconds > 0, do: now + ttl_seconds * 1000, else: nil

    registration = %{
      tenant_id: tenant_id,
      service_id: service_id,
      service_name: service_name,
      version: version || "1.0.0",
      metadata: metadata,
      handle: handle,
      registered_at: now,
      expires_at: expires_at
    }

    # Store in registrations
    registrations =
      Map.update(state.registrations, tenant_id, %{}, fn tenant_regs ->
        Map.put(tenant_regs, service_id, registration)
      end)

    # Update name index
    name_index =
      Map.update(state.name_index, service_name, [registration], fn regs ->
        [registration | regs]
      end)

    # Update handle map
    handle_map = Map.put(state.handle_map, handle, {tenant_id, service_id})

    Logger.info(
      "[ServiceRegistry] Registered #{service_name}/#{service_id} for #{tenant_id} (handle: #{handle})"
    )

    {:reply, {:ok, handle},
     %{state | registrations: registrations, name_index: name_index, handle_map: handle_map}}
  end

  def handle_call({:discover, tenant_id, service_name, filters}, _from, state) do
    registrations = Map.get(state.name_index, service_name, [])

    # Filter by tenant
    filtered =
      registrations
      |> Enum.filter(fn reg -> reg.tenant_id == tenant_id and not expired?(reg) end)
      |> Enum.filter(fn reg -> matches_filters?(reg.metadata, filters) end)

    {:reply, {:ok, filtered}, state}
  end

  def handle_call({:list, tenant_id, service_name}, _from, state) do
    tenant_regs = Map.get(state.registrations, tenant_id, %{})

    results =
      tenant_regs
      |> Enum.filter(fn {_id, reg} -> not expired?(reg) end)
      |> Enum.filter(fn {_id, reg} -> service_name == nil or reg.service_name == service_name end)
      |> Enum.map(fn {_id, reg} -> reg end)

    {:reply, {:ok, results}, state}
  end

  def handle_call({:unregister, tenant_id, service_id}, _from, state) do
    case get_in(state.registrations, [tenant_id, service_id]) do
      nil ->
        {:reply, {:error, :not_found}, state}

      registration ->
        # Remove from registrations
        registrations =
          update_in(state.registrations, [tenant_id], fn tenant_regs ->
            Map.delete(tenant_regs, service_id)
          end)

        # Remove from name index
        name_index =
          Map.update(state.name_index, registration.service_name, [], fn regs ->
            Enum.reject(regs, fn r -> r.handle == registration.handle end)
          end)

        # Remove from handle map
        handle_map = Map.delete(state.handle_map, registration.handle)

        Logger.info(
          "[ServiceRegistry] Unregistered #{registration.service_name}/#{service_id} from #{tenant_id}"
        )

        {:reply, :ok,
         %{state | registrations: registrations, name_index: name_index, handle_map: handle_map}}
    end
  end

  def handle_call({:get_metadata, tenant_id, service_id}, _from, state) do
    case get_in(state.registrations, [tenant_id, service_id]) do
      nil -> {:reply, nil, state}
      registration -> {:reply, registration.metadata, state}
    end
  end

  def handle_call({:get_handle, tenant_id, service_id}, _from, state) do
    case get_in(state.registrations, [tenant_id, service_id]) do
      nil -> {:reply, nil, state}
      registration -> {:reply, registration.handle, state}
    end
  end

  @impl GenServer
  def handle_info(:cleanup_expired, state) do
    now = System.os_time(:millisecond)

    registrations =
      Enum.reduce(state.registrations, %{}, fn {tenant_id, tenant_regs}, acc ->
        filtered =
          Enum.reject(tenant_regs, fn {_id, reg} ->
            reg.expires_at && reg.expires_at < now
          end)
          |> Map.new()

        if map_size(filtered) > 0 do
          Map.put(acc, tenant_id, filtered)
        else
          acc
        end
      end)

    # Clean up indices
    name_index =
      Enum.reduce(state.name_index, %{}, fn {name, regs}, acc ->
        filtered = Enum.reject(regs, &expired?/1)

        if Enum.any?(filtered) do
          Map.put(acc, name, filtered)
        else
          acc
        end
      end)

    handle_map =
      Enum.reject(state.handle_map, fn {_handle, {tenant_id, service_id}} ->
        case get_in(registrations, [tenant_id, service_id]) do
          nil -> true
          _ -> false
        end
      end)
      |> Map.new()

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_expired, 60000)

    {:noreply,
     %{state | registrations: registrations, name_index: name_index, handle_map: handle_map}}
  end

  # === Private Helpers ===

  defp expired?(registration) do
    case registration.expires_at do
      nil -> false
      expires_at -> System.os_time(:millisecond) >= expires_at
    end
  end

  defp matches_filters?(metadata, filters) when is_map(metadata) and is_map(filters) do
    Enum.all?(filters, fn {key, value} ->
      Map.get(metadata, key) == value
    end)
  end

  defp matches_filters?(_metadata, _filters), do: true

  defp generate_handle do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
