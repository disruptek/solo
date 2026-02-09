defmodule Solo.Backpressure.CircuitBreakerTest do
  use ExUnit.Case

  describe "CircuitBreaker" do
    test "starts in closed state" do
      {:ok, breaker} =
        Solo.Backpressure.CircuitBreaker.start_link(
          tenant_id: "tenant_1",
          service_id: "service_1"
        )

      assert :closed = Solo.Backpressure.CircuitBreaker.state(breaker)
    end

    test "allows successful calls when closed" do
      {:ok, breaker} =
        Solo.Backpressure.CircuitBreaker.start_link(
          tenant_id: "tenant_1",
          service_id: "service_1"
        )

      {:ok, result} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> :ok end)
      assert result == :ok
    end

    test "opens after failure threshold" do
      {:ok, breaker} =
        Solo.Backpressure.CircuitBreaker.start_link(
          tenant_id: "tenant_1",
          service_id: "service_1",
          failure_threshold: 2
        )

      # Fail twice
      {:error, _} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> raise "error" end)
      {:error, _} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> raise "error" end)

      # Should be open now
      assert :open = Solo.Backpressure.CircuitBreaker.state(breaker)
    end

    test "rejects calls when open" do
      {:ok, breaker} =
        Solo.Backpressure.CircuitBreaker.start_link(
          tenant_id: "tenant_1",
          service_id: "service_1",
          failure_threshold: 1
        )

      # Fail once to open the circuit
      {:error, _} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> raise "error" end)

      # Next call should be rejected
      {:error, :circuit_breaker_open} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> :ok end)
    end

    test "recovers from half-open state" do
      {:ok, breaker} =
        Solo.Backpressure.CircuitBreaker.start_link(
          tenant_id: "tenant_1",
          service_id: "service_1",
          failure_threshold: 1,
          reset_timeout_ms: 100,
          success_threshold: 1
        )

      # Fail to open
      {:error, _} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> raise "error" end)
      assert :open = Solo.Backpressure.CircuitBreaker.state(breaker)

      # Wait for reset timeout
      Process.sleep(150)

      # Attempt recovery - should transition to half-open and succeed
      {:ok, :recovered} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> :recovered end)

      # Should be closed now
      assert :closed = Solo.Backpressure.CircuitBreaker.state(breaker)
    end

    test "emits events for open and close" do
      last_id = Solo.EventStore.last_id()

      {:ok, breaker} =
        Solo.Backpressure.CircuitBreaker.start_link(
          tenant_id: "tenant_1",
          service_id: "test_service",
          failure_threshold: 1,
          reset_timeout_ms: 100,
          success_threshold: 1
        )

      # Open the circuit
      {:error, _} = Solo.Backpressure.CircuitBreaker.call(breaker, fn -> raise "error" end)

      Process.sleep(100)

      # Get events
      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      open_events = Enum.filter(events, &(&1.event_type == :circuit_breaker_opened))

      assert length(open_events) >= 1
    end
  end
end
