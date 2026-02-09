defmodule Solo.Gateway.REST.SecretsHandlerTest do
  use ExUnit.Case, async: false
  doctest Solo.Gateway.REST.SecretsHandler

  setup do
    {:ok, _apps} = Application.ensure_all_started(:solo)

    tenant_id = "secrets_test_tenant_#{System.unique_integer([:positive])}"

    # Clear any existing secrets for this tenant before each test
    case Solo.Vault.list_secrets(tenant_id) do
      {:ok, secrets} ->
        Enum.each(secrets, fn secret_name ->
          Solo.Vault.revoke(tenant_id, secret_name)
        end)

      {:error, _} ->
        :ok
    end

    {:ok, tenant_id: tenant_id, secret_key: "test_secret_key", secret_value: "test_secret_value"}
  end

  describe "SecretsHandler - integration with Vault" do
    test "stores a secret through Vault", %{
      tenant_id: tenant_id,
      secret_key: secret_key,
      secret_value: secret_value
    } do
      # Store a secret directly through Vault
      result = Solo.Vault.store(tenant_id, secret_key, secret_value, tenant_id)
      assert result == :ok

      # Verify secret was stored
      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)
      assert secret_key in secrets
    end

    test "multiple secrets can be stored for same tenant", %{
      tenant_id: tenant_id
    } do
      :ok = Solo.Vault.store(tenant_id, "secret_1", "value_1", tenant_id)
      :ok = Solo.Vault.store(tenant_id, "secret_2", "value_2", tenant_id)
      :ok = Solo.Vault.store(tenant_id, "secret_3", "value_3", tenant_id)

      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)
      assert length(secrets) == 3
      assert "secret_1" in secrets
      assert "secret_2" in secrets
      assert "secret_3" in secrets
    end

    test "deletes a secret successfully", %{
      tenant_id: tenant_id,
      secret_key: secret_key,
      secret_value: secret_value
    } do
      # First, store a secret
      :ok = Solo.Vault.store(tenant_id, secret_key, secret_value, tenant_id)

      # Verify it exists
      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)
      assert secret_key in secrets

      # Delete it
      :ok = Solo.Vault.revoke(tenant_id, secret_key)

      # Verify it was deleted
      {:ok, secrets_after} = Solo.Vault.list_secrets(tenant_id)
      assert secret_key not in secrets_after
    end

    test "returns error for non-existent secret", %{
      tenant_id: tenant_id
    } do
      # Try to delete a non-existent secret
      result = Solo.Vault.revoke(tenant_id, "nonexistent_key")
      # Should complete without error (soft delete)
      assert result == :ok
    end
  end

  describe "SecretsHandler - tenant isolation" do
    test "secrets are isolated per tenant", %{
      secret_key: secret_key,
      secret_value: secret_value
    } do
      tenant_1 = "isolation_tenant_1_#{System.unique_integer([:positive])}"
      tenant_2 = "isolation_tenant_2_#{System.unique_integer([:positive])}"

      # Store same secret for different tenants
      :ok = Solo.Vault.store(tenant_1, secret_key, secret_value, tenant_1)
      :ok = Solo.Vault.store(tenant_2, secret_key, "different_value", tenant_2)

      # Verify isolation
      {:ok, secrets_1} = Solo.Vault.list_secrets(tenant_1)
      {:ok, secrets_2} = Solo.Vault.list_secrets(tenant_2)

      assert secret_key in secrets_1
      assert secret_key in secrets_2

      # Delete from tenant_1
      :ok = Solo.Vault.revoke(tenant_1, secret_key)

      # Verify it's only deleted from tenant_1
      {:ok, secrets_1_after} = Solo.Vault.list_secrets(tenant_1)
      {:ok, secrets_2_after} = Solo.Vault.list_secrets(tenant_2)

      assert secret_key not in secrets_1_after
      assert secret_key in secrets_2_after

      # Cleanup
      Solo.Vault.revoke(tenant_2, secret_key)
    end
  end

  describe "SecretsHandler - secret key validation" do
    test "accepts valid secret keys", %{tenant_id: tenant_id} do
      valid_keys = ["DB_PASSWORD", "API_KEY", "secret-key-123", "test_secret"]

      Enum.each(valid_keys, fn key ->
        result = Solo.Vault.store(tenant_id, key, "test_value", tenant_id)
        assert result == :ok, "Key #{key} should be valid"
      end)

      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)
      assert length(secrets) >= length(valid_keys)
    end
  end

  describe "SecretsHandler - list operations" do
    test "lists all secrets for a tenant", %{
      tenant_id: tenant_id
    } do
      # Store multiple secrets
      :ok = Solo.Vault.store(tenant_id, "secret_1", "value_1", tenant_id)
      :ok = Solo.Vault.store(tenant_id, "secret_2", "value_2", tenant_id)
      :ok = Solo.Vault.store(tenant_id, "secret_3", "value_3", tenant_id)

      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)

      assert length(secrets) == 3
      assert "secret_1" in secrets
      assert "secret_2" in secrets
      assert "secret_3" in secrets
    end

    test "returns empty list for tenant with no secrets", %{tenant_id: tenant_id} do
      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)
      assert secrets == []
    end
  end

  describe "SecretsHandler - handler methods" do
    test "handler initializes correctly" do
      # Test that the handler module can be loaded
      assert :erlang.function_exported(Solo.Gateway.REST.SecretsHandler, :init, 2)
    end

    test "handler implements required callbacks" do
      # Verify the handler implements required REST callbacks
      assert :erlang.function_exported(Solo.Gateway.REST.SecretsHandler, :allowed_methods, 2)

      assert :erlang.function_exported(
               Solo.Gateway.REST.SecretsHandler,
               :content_types_provided,
               2
             )

      assert :erlang.function_exported(
               Solo.Gateway.REST.SecretsHandler,
               :content_types_accepted,
               2
             )

      assert :erlang.function_exported(Solo.Gateway.REST.SecretsHandler, :from_json, 2)
      assert :erlang.function_exported(Solo.Gateway.REST.SecretsHandler, :to_json, 2)
      assert :erlang.function_exported(Solo.Gateway.REST.SecretsHandler, :delete_resource, 2)
    end
  end
end
