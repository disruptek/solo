defmodule Solo.Registry do
  @moduledoc """
  Thin wrapper around Elixir's Registry for service discovery.

  Services are registered by {tenant_id, service_id} tuple.
  """

  @doc """
  Start the Registry supervision tree.
  """
  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Register a service process.

  Returns {:ok, pid} on success or {:error, {:already_registered, pid}} if already registered.
  """
  @spec register(String.t(), String.t(), pid()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(tenant_id, service_id, pid) when is_binary(tenant_id) and is_binary(service_id) and is_pid(pid) do
    case Registry.register(__MODULE__, {tenant_id, service_id}, pid) do
      {:ok, _owner_pid} -> {:ok, pid}
      {:error, {:already_registered, existing_pid}} -> {:error, {:already_registered, existing_pid}}
    end
  end

  @doc """
  Lookup a service by tenant and service ID.

  Returns [{pid, _meta}] if found, [] if not found.
  """
  @spec lookup(String.t(), String.t()) :: [{pid(), any()}]
  def lookup(tenant_id, service_id) when is_binary(tenant_id) and is_binary(service_id) do
    Registry.lookup(__MODULE__, {tenant_id, service_id})
  end

  @doc """
  Get all services for a tenant.

  Returns a list of {service_id, pid} tuples.
  """
  @spec list_for_tenant(String.t()) :: [{String.t(), pid()}]
  def list_for_tenant(tenant_id) when is_binary(tenant_id) do
    Registry.select(__MODULE__, [
      {{{:"$0", :"$1"}, :_, :"$2"}, [{:==, :"$0", {:const, tenant_id}}], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc """
  Unregister a service (called when it terminates).

  Returns :ok even if not registered.
  """
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(tenant_id, service_id) when is_binary(tenant_id) and is_binary(service_id) do
    Registry.unregister(__MODULE__, {tenant_id, service_id})
  end
end
