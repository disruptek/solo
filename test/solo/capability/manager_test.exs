defmodule Solo.Capability.ManagerTest do
  use ExUnit.Case

  describe "Capability.Manager.grant/4" do
    test "grants a capability token" do
      {:ok, token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read", "write"], 3600)

      assert is_binary(token)
      assert byte_size(token) > 0
    end

    test "emits capability_granted event" do
      last_id = Solo.EventStore.last_id()

      {:ok, _token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 3600)

      Process.sleep(100)
      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      grant_events = Enum.filter(events, &(&1.event_type == :capability_granted))

      assert length(grant_events) >= 1
    end
  end

  describe "Capability.Manager.verify/3" do
    test "valid token passes verification" do
      {:ok, token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read", "write"], 3600)

      assert :ok = Solo.Capability.Manager.verify(token, "filesystem", "read")
    end

    test "invalid token fails" do
      {:ok, _token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 3600)

      wrong_token = :crypto.strong_rand_bytes(32)

      assert {:error, "Capability not found"} =
               Solo.Capability.Manager.verify(wrong_token, "filesystem", "read")
    end

    test "wrong resource fails" do
      {:ok, token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 3600)

      assert {:error, "Capability is for different resource"} =
               Solo.Capability.Manager.verify(token, "eventstore", "read")
    end

    test "permission not allowed fails" do
      {:ok, token} = Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 3600)

      assert {:error, "Capability does not allow write"} =
               Solo.Capability.Manager.verify(token, "filesystem", "write")
    end

    test "expired token fails" do
      {:ok, token} = Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 1)

      # Wait for token to expire
      Process.sleep(1100)

      assert {:error, "Capability expired or revoked"} =
               Solo.Capability.Manager.verify(token, "filesystem", "read")
    end
  end

  describe "Capability.Manager.revoke/1" do
    test "revokes a capability" do
      {:ok, token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 3600)

      token_hash = :crypto.hash(:sha256, token)
      :ok = Solo.Capability.Manager.revoke(token_hash)

      # Token should no longer verify
      assert {:error, "Capability expired or revoked"} =
               Solo.Capability.Manager.verify(token, "filesystem", "read")
    end

    test "emits capability_revoked event" do
      last_id = Solo.EventStore.last_id()

      {:ok, token} =
        Solo.Capability.Manager.grant("tenant_1", "filesystem", ["read"], 3600)

      token_hash = :crypto.hash(:sha256, token)
      :ok = Solo.Capability.Manager.revoke(token_hash)

      Process.sleep(100)
      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      revoke_events = Enum.filter(events, &(&1.event_type == :capability_revoked))

      assert length(revoke_events) >= 1
    end
  end
end
