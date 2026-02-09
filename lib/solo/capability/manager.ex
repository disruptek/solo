defmodule Solo.Capability.Manager do
  @moduledoc """
  Manages the lifecycle of capability tokens.

  Responsibilities:
  - Grant new capabilities to services
  - Revoke capabilities
  - Verify capabilities at runtime
  - Periodic cleanup of expired tokens

  Capabilities are stored in ETS for fast lookup.
  """

  use GenServer

  require Logger

  @check_interval 60_000  # 1 minute - clean up expired tokens

  @doc """
  Start the Capability.Manager GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Grant a new capability to a tenant for a resource.

  Returns `{:ok, token}` where token is the unforgeable capability token.
  """
  @spec grant(String.t(), Solo.Capability.resource_ref(), [Solo.Capability.permission()],
              non_neg_integer()) :: {:ok, Solo.Capability.token()}
  def grant(tenant_id, resource_ref, permissions, ttl_seconds)
      when is_binary(tenant_id) and is_binary(resource_ref) and is_list(permissions) and
             is_integer(ttl_seconds) do
    GenServer.call(__MODULE__, {:grant, tenant_id, resource_ref, permissions, ttl_seconds})
  end

  @doc """
  Revoke a capability by token hash.

  Returns `:ok`.
  """
  @spec revoke(binary()) :: :ok
  def revoke(token_hash) when is_binary(token_hash) do
    GenServer.call(__MODULE__, {:revoke, token_hash})
  end

  @doc """
  Verify a capability token for a specific permission.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec verify(Solo.Capability.token(), String.t(), Solo.Capability.permission()) ::
          :ok | {:error, String.t()}
  def verify(token, resource_ref, required_permission)
      when is_binary(token) and is_binary(resource_ref) and is_binary(required_permission) do
    GenServer.call(__MODULE__, {:verify, token, resource_ref, required_permission})
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init([]) do
    Logger.info("[Capability.Manager] Started")

    # Create ETS table for storing capabilities
    # token_hash -> capability
    :ets.new(:capabilities, [:named_table, :public, {:read_concurrency, true}])

    schedule_cleanup()

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:grant, tenant_id, resource_ref, permissions, ttl_seconds}, _from, state) do
    {:ok, token, capability} =
      Solo.Capability.create(resource_ref, permissions, ttl_seconds, tenant_id)

    # Store capability by token hash
    :ets.insert(:capabilities, {capability.token_hash, capability})

    # Emit event
    Solo.EventStore.emit(:capability_granted, {tenant_id, resource_ref}, %{
      resource_ref: resource_ref,
      permissions: permissions,
      ttl_seconds: ttl_seconds,
      tenant_id: tenant_id
    })

    Logger.debug("[Capability.Manager] Granted capability for #{resource_ref} to #{tenant_id}")

    {:reply, {:ok, token}, state}
  end

  def handle_call({:revoke, token_hash}, _from, state) do
    case :ets.lookup(:capabilities, token_hash) do
      [{_hash, cap}] ->
        revoked_cap = Solo.Capability.revoke(cap)
        :ets.insert(:capabilities, {token_hash, revoked_cap})

        # Emit event
        Solo.EventStore.emit(:capability_revoked, {cap.tenant_id, cap.resource_ref}, %{
          resource_ref: cap.resource_ref,
          tenant_id: cap.tenant_id
        })

        Logger.debug("[Capability.Manager] Revoked capability")

      [] ->
        Logger.warning("[Capability.Manager] Attempted to revoke unknown capability")
    end

    {:reply, :ok, state}
  end

  def handle_call({:verify, token, resource_ref, required_permission}, _from, state) do
    token_hash = :crypto.hash(:sha256, token)

    result =
      case :ets.lookup(:capabilities, token_hash) do
        [{_hash, cap}] ->
          cond do
            not Solo.Capability.valid?(cap) ->
              {:error, "Capability expired or revoked"}

            cap.resource_ref != resource_ref ->
              Solo.EventStore.emit(:capability_denied, {cap.tenant_id, resource_ref}, %{
                reason: "resource_mismatch",
                required_resource: resource_ref,
                actual_resource: cap.resource_ref,
                tenant_id: cap.tenant_id
              })

              {:error, "Capability is for different resource"}

            not Solo.Capability.allows?(cap, required_permission) ->
              Solo.EventStore.emit(:capability_denied, {cap.tenant_id, resource_ref}, %{
                reason: "permission_denied",
                required_permission: required_permission,
                tenant_id: cap.tenant_id
              })

              {:error, "Capability does not allow #{required_permission}"}

            true ->
              Solo.EventStore.emit(:capability_verified, {cap.tenant_id, resource_ref}, %{
                resource_ref: resource_ref,
                permission: required_permission,
                tenant_id: cap.tenant_id
              })

              :ok
          end

        [] ->
          {:error, "Capability not found"}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    # Remove expired capabilities by iterating and checking expiration
    now = System.system_time(:second)

    :ets.foldl(
      fn {_token_hash, cap}, acc ->
        if cap.expires_at <= now do
          :ets.delete(:capabilities, cap.token_hash)
        end

        acc
      end,
      nil,
      :capabilities
    )

    schedule_cleanup()
    {:noreply, state}
  end

  # === Private Helpers ===

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @check_interval)
  end
end
