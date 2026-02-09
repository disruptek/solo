defmodule Solo.Backpressure.LoadShedderTest do
  use ExUnit.Case

  setup do
    # Tests use unique tenant IDs to avoid cross-test interference
    :ok
  end

  describe "LoadShedder" do
    test "allows requests within limits" do
      tenant = "test_tenant_#{System.unique_integer()}"
      assert :ok = Solo.Backpressure.LoadShedder.check_request(tenant)
    end

    test "acquires and releases tokens" do
      tenant = "test_tenant_#{System.unique_integer()}"
      {:ok, token} = Solo.Backpressure.LoadShedder.acquire(tenant)
      assert is_reference(token)

      :ok = Solo.Backpressure.LoadShedder.release(token)
    end

    test "rejects requests at capacity" do
      tenant = "test_tenant_#{System.unique_integer()}"
      # Fill up to limit
      tokens =
        Enum.map(1..100, fn _i ->
          {:ok, token} = Solo.Backpressure.LoadShedder.acquire(tenant)
          token
        end)

      # Next request should be rejected
      assert {:error, :overloaded} = Solo.Backpressure.LoadShedder.acquire(tenant)

      # Release one and try again
      Solo.Backpressure.LoadShedder.release(Enum.at(tokens, 0))
      assert {:ok, _token} = Solo.Backpressure.LoadShedder.acquire(tenant)

      # Cleanup
      Enum.each(tokens, &Solo.Backpressure.LoadShedder.release/1)
      # Give async releases time to process
      Process.sleep(10)
    end

    test "tracks per-tenant limits separately" do
      tenant_1 = "test_tenant_1_#{System.unique_integer()}"
      tenant_2 = "test_tenant_2_#{System.unique_integer()}"

      # Fill tenant_1
      tokens_1 =
        Enum.map(1..100, fn _i ->
          {:ok, token} = Solo.Backpressure.LoadShedder.acquire(tenant_1)
          token
        end)

      # tenant_2 should still have capacity
      assert {:ok, token_2} = Solo.Backpressure.LoadShedder.acquire(tenant_2)

      # Cleanup
      Enum.each(tokens_1, &Solo.Backpressure.LoadShedder.release/1)
      Solo.Backpressure.LoadShedder.release(token_2)
      # Give async releases time to process
      Process.sleep(10)
    end

    test "provides load statistics" do
      tenant = "test_tenant_#{System.unique_integer()}"
      {:ok, token1} = Solo.Backpressure.LoadShedder.acquire(tenant)
      {:ok, token2} = Solo.Backpressure.LoadShedder.acquire(tenant)

      stats = Solo.Backpressure.LoadShedder.stats()

      assert stats.per_tenant[tenant] == 2
      assert stats.total_in_flight >= 2
      assert stats.num_tenants >= 1

      Solo.Backpressure.LoadShedder.release(token1)
      Solo.Backpressure.LoadShedder.release(token2)
      # Give async releases time to process
      Process.sleep(10)
    end
  end
end
