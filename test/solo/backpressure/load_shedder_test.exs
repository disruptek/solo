defmodule Solo.Backpressure.LoadShedderTest do
  use ExUnit.Case

  describe "LoadShedder" do
    test "allows requests within limits" do
      assert :ok = Solo.Backpressure.LoadShedder.check_request("tenant_1")
    end

    test "acquires and releases tokens" do
      {:ok, token} = Solo.Backpressure.LoadShedder.acquire("tenant_1")
      assert is_reference(token)

      :ok = Solo.Backpressure.LoadShedder.release(token)
    end

    test "rejects requests at capacity" do
      # Fill up to limit
      tokens =
        Enum.map(1..100, fn _i ->
          {:ok, token} = Solo.Backpressure.LoadShedder.acquire("tenant_1")
          token
        end)

      # Next request should be rejected
      assert {:error, :overloaded} = Solo.Backpressure.LoadShedder.acquire("tenant_1")

      # Release one and try again
      Solo.Backpressure.LoadShedder.release(Enum.at(tokens, 0))
      assert {:ok, _token} = Solo.Backpressure.LoadShedder.acquire("tenant_1")
    end

    test "tracks per-tenant limits separately" do
      # Fill tenant_1
      tokens_1 =
        Enum.map(1..100, fn _i ->
          {:ok, token} = Solo.Backpressure.LoadShedder.acquire("tenant_1")
          token
        end)

      # tenant_2 should still have capacity
      assert {:ok, _token} = Solo.Backpressure.LoadShedder.acquire("tenant_2")

      # Cleanup
      Enum.each(tokens_1, &Solo.Backpressure.LoadShedder.release/1)
    end

    test "provides load statistics" do
      {:ok, token1} = Solo.Backpressure.LoadShedder.acquire("tenant_1")
      {:ok, token2} = Solo.Backpressure.LoadShedder.acquire("tenant_1")

      stats = Solo.Backpressure.LoadShedder.stats()

      assert stats.per_tenant["tenant_1"] == 2
      assert stats.total_in_flight == 2
      assert stats.num_tenants == 1

      Solo.Backpressure.LoadShedder.release(token1)
      Solo.Backpressure.LoadShedder.release(token2)
    end
  end
end
