defmodule Solo.CapabilityTest do
  use ExUnit.Case

  describe "Capability.create/4" do
    test "creates a valid token" do
      {:ok, token, cap} =
        Solo.Capability.create("filesystem", ["read", "write"], 3600, "tenant_1")

      assert is_binary(token)
      assert byte_size(token) > 0
      assert cap.resource_ref == "filesystem"
      assert cap.permissions == ["read", "write"]
      assert cap.tenant_id == "tenant_1"
      assert not cap.revoked?
    end

    test "token is random" do
      {:ok, token1, _} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      {:ok, token2, _} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")

      assert token1 != token2
    end

    test "calculates expiration time" do
      before = System.system_time(:second)
      {:ok, _token, cap} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      after_time = System.system_time(:second)

      # Should expire in ~3600 seconds
      assert cap.expires_at >= before + 3599
      assert cap.expires_at <= after_time + 3601
    end
  end

  describe "Capability.valid?/1" do
    test "valid capability passes" do
      {:ok, _token, cap} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      assert Solo.Capability.valid?(cap)
    end

    test "revoked capability fails" do
      {:ok, _token, cap} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      revoked_cap = Solo.Capability.revoke(cap)

      assert not Solo.Capability.valid?(revoked_cap)
    end

    test "expired capability fails" do
      {:ok, _token, cap} = Solo.Capability.create("filesystem", ["read"], -1, "tenant_1")
      assert not Solo.Capability.valid?(cap)
    end
  end

  describe "Capability.allows?/2" do
    test "permission in list passes" do
      {:ok, _token, cap} =
        Solo.Capability.create("filesystem", ["read", "write"], 3600, "tenant_1")

      assert Solo.Capability.allows?(cap, "read")
      assert Solo.Capability.allows?(cap, "write")
    end

    test "permission not in list fails" do
      {:ok, _token, cap} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      assert not Solo.Capability.allows?(cap, "write")
    end
  end

  describe "Capability.verify_token/2" do
    test "correct token verifies" do
      {:ok, token, cap} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      assert Solo.Capability.verify_token(token, cap)
    end

    test "wrong token fails" do
      {:ok, _token, cap} = Solo.Capability.create("filesystem", ["read"], 3600, "tenant_1")
      wrong_token = :crypto.strong_rand_bytes(32)

      assert not Solo.Capability.verify_token(wrong_token, cap)
    end
  end
end
