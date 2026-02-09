defmodule Solo.Tenant.Supervisor do
  @moduledoc """
  Top-level DynamicSupervisor for managing tenant supervision hierarchies.

  When the first service for a tenant is deployed, a per-tenant supervisor is
  dynamically created. When all services for a tenant are killed, the supervisor
  is destroyed.

  This ensures complete isolation between tenants.
  """

  use DynamicSupervisor

  require Logger

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init([]) do
    Logger.info("[Tenant.Supervisor] Started")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Get or create a tenant supervisor.

  Returns the PID of the per-tenant supervisor.
  """
  @spec get_or_create_tenant(String.t()) :: {:ok, pid()} | {:error, any()}
  def get_or_create_tenant(tenant_id) when is_binary(tenant_id) do
    case lookup_tenant(tenant_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        spec = {Solo.Tenant.ServiceSupervisor, [tenant_id: tenant_id]}
        DynamicSupervisor.start_child(__MODULE__, spec)
    end
  end

  @doc """
  Lookup a tenant supervisor by tenant_id.
  """
  @spec lookup_tenant(String.t()) :: {:ok, pid()} | :error
  def lookup_tenant(tenant_id) when is_binary(tenant_id) do
    case Registry.lookup(Solo.Registry, {:tenant, tenant_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
