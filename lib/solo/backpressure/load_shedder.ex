defmodule Solo.Backpressure.LoadShedder do
  @moduledoc """
  Gateway-level load shedding to prevent overload.

  Tracks in-flight requests per tenant and rejects new requests when
  capacity is reached. This prevents cascading failures from spreading
  back to the agent.

  Configuration:
  - `max_per_tenant`: Maximum in-flight requests per tenant (default 100)
  - `max_total`: Maximum in-flight requests globally (default 1000)
  """

  use GenServer

  require Logger

  @doc """
  Start the load shedder.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Check if a request should be allowed.

  Returns `:ok` if within limits, `{:error, :overloaded}` if shedding.
  """
  @spec check_request(String.t()) :: :ok | {:error, :overloaded}
  def check_request(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:check, tenant_id})
  end

  @doc """
  Increment in-flight request count.

  Returns a token that must be passed to release_request/1.
  """
  @spec acquire(String.t()) :: {:ok, reference()} | {:error, :overloaded}
  def acquire(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:acquire, tenant_id})
  end

  @doc """
  Decrement in-flight request count.
  """
  @spec release(reference()) :: :ok
  def release(token) when is_reference(token) do
    GenServer.cast(__MODULE__, {:release, token})
  end

  @doc """
  Get current load statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl GenServer
  def init([]) do
    Logger.info("[LoadShedder] Started")

    {:ok,
     %{
       # tenant_id -> count of in-flight requests
       per_tenant: %{},
       # ref -> tenant_id mapping
       tokens: %{},
       max_per_tenant: 100,
       max_total: 1000
     }}
  end

  @impl GenServer
  def handle_call({:check, tenant_id}, _from, state) do
    tenant_count = Map.get(state.per_tenant, tenant_id, 0)
    total_count = Enum.sum(Map.values(state.per_tenant))

    if tenant_count >= state.max_per_tenant or total_count >= state.max_total do
      Logger.warning(
        "[LoadShedder] Shedding request for #{tenant_id} (tenant: #{tenant_count}/#{state.max_per_tenant}, total: #{total_count}/#{state.max_total})"
      )

      {:reply, {:error, :overloaded}, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:acquire, tenant_id}, _from, state) do
    tenant_count = Map.get(state.per_tenant, tenant_id, 0)
    total_count = Enum.sum(Map.values(state.per_tenant))

    if tenant_count >= state.max_per_tenant or total_count >= state.max_total do
      {:reply, {:error, :overloaded}, state}
    else
      token = make_ref()

      state = %{
        state
        | per_tenant: Map.update(state.per_tenant, tenant_id, 1, &(&1 + 1)),
          tokens: Map.put(state.tokens, token, tenant_id)
      }

      {:reply, {:ok, token}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    total_count = Enum.sum(Map.values(state.per_tenant))

    stats = %{
      per_tenant: state.per_tenant,
      total_in_flight: total_count,
      max_per_tenant: state.max_per_tenant,
      max_total: state.max_total,
      num_tenants: map_size(state.per_tenant)
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:release, token}, state) do
    case Map.get(state.tokens, token) do
      nil ->
        # Already released or invalid token
        state

      tenant_id ->
        new_count = Map.get(state.per_tenant, tenant_id, 1) - 1

        state = %{
          state
          | per_tenant:
              if new_count <= 0 do
                Map.delete(state.per_tenant, tenant_id)
              else
                Map.put(state.per_tenant, tenant_id, new_count)
              end,
            tokens: Map.delete(state.tokens, token)
        }

        {:noreply, state}
    end
  end
end
