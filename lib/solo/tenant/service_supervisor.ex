defmodule Solo.Tenant.ServiceSupervisor do
  @moduledoc """
  Per-tenant supervisor that manages all services for a single tenant.

  Uses :one_for_one strategy: if one service crashes, only that service is restarted.
  The supervisor is dynamically created when the first service for a tenant is deployed,
  and destroyed when all services are killed.

  Each service is wrapped in its own supervision layer (Phase 2) with configurable
  restart limits.
  """

  use DynamicSupervisor

  require Logger

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    DynamicSupervisor.start_link(__MODULE__, [tenant_id: tenant_id], name: via_tuple(tenant_id))
  end

  @impl DynamicSupervisor
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    Logger.info("[Tenant.ServiceSupervisor] Started for tenant #{tenant_id}")

    # Register this supervisor in the registry so it can be looked up
    Registry.register(Solo.Registry, {:tenant, tenant_id}, tenant_id)

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Get the via tuple for a tenant's supervisor.
  """
  def via_tuple(tenant_id) do
    {:via, Registry, {Solo.Registry, {:tenant_service_supervisor, tenant_id}}}
  end
end
