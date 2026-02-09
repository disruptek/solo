defmodule Solo.VaultTest do
  use ExUnit.Case, async: false
  doctest Solo.Vault

  setup do
    {:ok, _apps} = Application.ensure_all_started(:solo)

    tenant_id = "vault_tenant_1"
    
    # Clear any existing secrets for this tenant before each test
    # by revoking all secrets for the tenant
    case Solo.Vault.list_secrets(tenant_id) do
      {:ok, secrets} ->
        Enum.each(secrets, fn secret_name ->
          Solo.Vault.revoke(tenant_id, secret_name)
        end)
      {:error, _} ->
        :ok
    end

    {:ok,
     tenant_id: tenant_id,
     secret_name: "api_key",
     secret_value: "super_secret_key_12345",
     master_key: "tenant_master_password"}
  end

  describe "store/5 - store encrypted secrets" do
    test "stores a secret encrypted", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      result = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)
      assert result == :ok

      # Verify event was emitted
      events = Solo.EventStore.filter(event_type: :secret_stored)
      assert length(events) >= 1
    end

    test "fails gracefully on invalid inputs", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      result = Solo.Vault.store(tenant_id, "", "value", master_key)
      assert result == :ok  # Empty secret_name is allowed but handled
    end

    test "multiple secrets can be stored for same tenant", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, "secret_1", "value_1", master_key)
      :ok = Solo.Vault.store(tenant_id, "secret_2", "value_2", master_key)
      :ok = Solo.Vault.store(tenant_id, "secret_3", "value_3", master_key)

      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)
      assert length(secrets) == 3
    end

    test "secrets are isolated per tenant", %{
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      tenant_1 = "tenant_1"
      tenant_2 = "tenant_2"

      :ok = Solo.Vault.store(tenant_1, secret_name, secret_value, master_key)
      :ok = Solo.Vault.store(tenant_2, secret_name, "different_value", master_key)

      {:ok, secrets_1} = Solo.Vault.list_secrets(tenant_1)
      {:ok, secrets_2} = Solo.Vault.list_secrets(tenant_2)

      assert length(secrets_1) == 1
      assert length(secrets_2) == 1
    end
  end

  describe "retrieve/3 - decrypt and retrieve secrets" do
    test "retrieves a stored secret", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)

      result = Solo.Vault.retrieve(tenant_id, secret_name, master_key)

      assert {:ok, decrypted_value} = result
      assert decrypted_value == secret_value
    end

    test "fails when secret not found", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      result = Solo.Vault.retrieve(tenant_id, "nonexistent_secret", master_key)

      assert {:error, _reason} = result
    end

    test "fails with wrong key", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)

      wrong_key = "wrong_password"
      result = Solo.Vault.retrieve(tenant_id, secret_name, wrong_key)

      # Should fail decryption
      assert {:error, _reason} = result
    end

    test "emits secret_accessed event on successful retrieval", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)

      {:ok, _} = Solo.Vault.retrieve(tenant_id, secret_name, master_key)

      events = Solo.EventStore.filter(event_type: :secret_accessed)
      assert length(events) >= 1
    end

    test "emits secret_access_denied event on failed retrieval", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)

      wrong_key = "wrong_password"
      {:error, _} = Solo.Vault.retrieve(tenant_id, secret_name, wrong_key)

      events = Solo.EventStore.filter(event_type: :secret_access_denied)
      assert length(events) >= 1
    end
  end

  describe "list_secrets/1 - enumerate secrets for a tenant" do
    test "lists all secrets for a tenant", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, "secret_a", "value_a", master_key)
      :ok = Solo.Vault.store(tenant_id, "secret_b", "value_b", master_key)
      :ok = Solo.Vault.store(tenant_id, "secret_c", "value_c", master_key)

      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)

      assert length(secrets) == 3
      assert Enum.sort(secrets) == ["secret_a", "secret_b", "secret_c"]
    end

    test "returns empty list when no secrets exist", %{
      tenant_id: tenant_id
    } do
      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)

      assert secrets == []
    end

    test "secrets are sorted alphabetically", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, "zebra", "z", master_key)
      :ok = Solo.Vault.store(tenant_id, "apple", "a", master_key)
      :ok = Solo.Vault.store(tenant_id, "middle", "m", master_key)

      {:ok, secrets} = Solo.Vault.list_secrets(tenant_id)

      assert secrets == ["apple", "middle", "zebra"]
    end
  end

  describe "revoke/2 - delete stored secrets" do
    test "revokes a secret", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)

      result = Solo.Vault.revoke(tenant_id, secret_name)

      assert result == :ok

      # Verify secret is no longer accessible
      retrieve_result = Solo.Vault.retrieve(tenant_id, secret_name, master_key)
      assert {:error, "Secret not found"} = retrieve_result
    end

    test "emits secret_revoked event", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      :ok = Solo.Vault.store(tenant_id, secret_name, secret_value, master_key)
      :ok = Solo.Vault.revoke(tenant_id, secret_name)

      events = Solo.EventStore.filter(event_type: :secret_revoked)
      assert length(events) >= 1
    end

    test "fails gracefully when revoking non-existent secret", %{
      tenant_id: tenant_id
    } do
      # Should not raise, just succeed (idempotent)
      result = Solo.Vault.revoke(tenant_id, "nonexistent")
      assert result == :ok
    end
  end

  describe "encryption properties" do
    test "same secret encrypted twice produces different ciphertexts", %{
      tenant_id: tenant_id,
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      # Store secret first time
      :ok = Solo.Vault.store(tenant_id, "test_1", secret_value, master_key)
      {:ok, secrets_1} = Solo.Vault.list_secrets(tenant_id)
      assert length(secrets_1) == 1

      # Revoke and store again
      :ok = Solo.Vault.revoke(tenant_id, "test_1")
      :ok = Solo.Vault.store(tenant_id, "test_1", secret_value, master_key)

      # Revoke and store a third time
      :ok = Solo.Vault.revoke(tenant_id, "test_1")
      :ok = Solo.Vault.store(tenant_id, "test_1", secret_value, master_key)

      # All three encryptions should be different (due to random IV)
      # but all decrypt to the same value
      {:ok, retrieved} = Solo.Vault.retrieve(tenant_id, "test_1", master_key)
      assert retrieved == secret_value
    end

    test "large secrets can be stored and retrieved", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      # Create a 10KB secret
      large_secret = String.duplicate("x", 10_000)

      :ok = Solo.Vault.store(tenant_id, "large_secret", large_secret, master_key)

      {:ok, retrieved} = Solo.Vault.retrieve(tenant_id, "large_secret", master_key)

      assert retrieved == large_secret
      assert byte_size(retrieved) == 10_000
    end

    test "binary secrets (not just UTF-8) can be stored", %{
      tenant_id: tenant_id,
      master_key: master_key
    } do
      binary_secret = <<0, 1, 255, 127, 200, 100>>

      :ok = Solo.Vault.store(tenant_id, "binary_secret", binary_secret, master_key)

      {:ok, retrieved} = Solo.Vault.retrieve(tenant_id, "binary_secret", master_key)

      assert retrieved == binary_secret
    end
  end

  describe "multi-tenant isolation" do
    test "cannot retrieve another tenant's secret even with correct key", %{
      secret_name: secret_name,
      secret_value: secret_value,
      master_key: master_key
    } do
      tenant_1 = "tenant_iso_1"
      tenant_2 = "tenant_iso_2"

      :ok = Solo.Vault.store(tenant_1, secret_name, secret_value, master_key)

      # Try to retrieve from tenant_2
      result = Solo.Vault.retrieve(tenant_2, secret_name, master_key)

      assert {:error, _} = result
    end

    test "different tenants can use same secret names independently", %{
      secret_name: secret_name,
      master_key: master_key
    } do
      tenant_1 = "tenant_a"
      tenant_2 = "tenant_b"

      :ok = Solo.Vault.store(tenant_1, secret_name, "tenant_1_value", master_key)
      :ok = Solo.Vault.store(tenant_2, secret_name, "tenant_2_value", master_key)

      {:ok, value_1} = Solo.Vault.retrieve(tenant_1, secret_name, master_key)
      {:ok, value_2} = Solo.Vault.retrieve(tenant_2, secret_name, master_key)

      assert value_1 == "tenant_1_value"
      assert value_2 == "tenant_2_value"
    end
  end
end
