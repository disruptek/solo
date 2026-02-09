defmodule Solo.TelemetryTest do
  use ExUnit.Case, async: false
  doctest Solo.Telemetry

  setup do
    {:ok, _apps} = Application.ensure_all_started(:solo)
    :ok
  end

  describe "emit/4 - emit telemetry events" do
    test "emits a telemetry event", _context do
      # Verify we can emit an event without error
      result = Solo.Telemetry.emit(:deployment, :deploy, %{duration_ms: 100}, %{service_id: "s1"})
      assert result == :ok
    end

    test "emits with empty measurements", _context do
      result = Solo.Telemetry.emit(:capability, :verify, %{}, %{tenant_id: "t1"})
      assert result == :ok
    end

    test "emits with empty metadata", _context do
      result = Solo.Telemetry.emit(:resource, :check, %{memory_bytes: 1000}, %{})
      assert result == :ok
    end

    test "emits with default parameters", _context do
      result = Solo.Telemetry.emit(:vault, :access)
      assert result == :ok
    end
  end

  describe "measure/3 - automatically measure function duration" do
    test "measures and returns function result", _context do
      result = Solo.Telemetry.measure(:deployment, :deploy, fn ->
        Process.sleep(10)
        :success
      end)

      assert result == :success
    end

    test "measures execution time", _context do
      result = Solo.Telemetry.measure(:hot_swap, :swap, fn ->
        Process.sleep(50)
        {:ok, "done"}
      end)

      assert {:ok, "done"} = result
    end

    test "propagates function exceptions", _context do
      assert_raise RuntimeError, fn ->
        Solo.Telemetry.measure(:capability, :verify, fn ->
          raise "test error"
        end)
      end
    end

    test "handles long-running functions", _context do
      result = Solo.Telemetry.measure(:resource, :check, fn ->
        Process.sleep(100)
        42
      end)

      assert result == 42
    end
  end

  describe "event channels" do
    test "deployment events can be emitted", _context do
      assert Solo.Telemetry.emit(:deployment, :start, %{service_id: "s1"}, %{tenant_id: "t1"}) == :ok
      assert Solo.Telemetry.emit(:deployment, :stop, %{duration_ms: 150}, %{status: :ok}) == :ok
    end

    test "hot_swap events can be emitted", _context do
      assert Solo.Telemetry.emit(:hot_swap, :start, %{}, %{service_id: "s1"}) == :ok
      assert Solo.Telemetry.emit(:hot_swap, :stop, %{duration_ms: 200}, %{method: :swap}) == :ok
    end

    test "capability events can be emitted", _context do
      assert Solo.Telemetry.emit(:capability, :verify, %{count: 1}, %{result: :granted}) == :ok
    end

    test "resource events can be emitted", _context do
      assert Solo.Telemetry.emit(:resource, :check, %{memory_mb: 256}, %{status: :ok}) == :ok
    end

    test "vault events can be emitted", _context do
      assert Solo.Telemetry.emit(:vault, :access, %{}, %{result: :success}) == :ok
    end
  end

  describe "measurements" do
    test "can include custom measurements", _context do
      measurements = %{
        duration_ms: 150,
        memory_bytes: 1_000_000,
        cpu_percent: 25.5
      }

      result = Solo.Telemetry.emit(:deployment, :stop, measurements, %{})
      assert result == :ok
    end

    test "measurements are flexible", _context do
      measurements = %{
        "custom_key" => "custom_value",
        :atom_key => 123
      }

      result = Solo.Telemetry.emit(:custom, :event, measurements, %{})
      assert result == :ok
    end
  end

  describe "metadata" do
    test "can include tenant and service context", _context do
      metadata = %{
        tenant_id: "t1",
        service_id: "s1",
        operation: "deploy"
      }

      result = Solo.Telemetry.emit(:deployment, :stop, %{duration_ms: 100}, metadata)
      assert result == :ok
    end

    test "metadata includes status and error info", _context do
      metadata = %{
        status: :failed,
        error: "Service not found",
        retry_count: 3
      }

      result = Solo.Telemetry.emit(:deployment, :stop, %{}, metadata)
      assert result == :ok
    end

    test "metadata can be nested", _context do
      metadata = %{
        tenant: %{id: "t1", name: "Tenant 1"},
        service: %{id: "s1", type: "agent"}
      }

      result = Solo.Telemetry.emit(:custom, :event, %{}, metadata)
      assert result == :ok
    end
  end

  describe "integration with application startup" do
    test "telemetry is running after application start", _context do
      # Verify telemetry module is loaded and can be called
      assert is_atom(Solo.Telemetry)
      assert function_exported?(Solo.Telemetry, :emit, 4)
      assert function_exported?(Solo.Telemetry, :measure, 3)
    end

    test "multiple events can be emitted in sequence", _context do
      for i <- 1..10 do
        result = Solo.Telemetry.emit(:test, :event, %{count: i}, %{})
        assert result == :ok
      end
    end
  end

  describe "performance characteristics" do
    test "emit is fast (non-blocking)", _context do
      start_time = System.monotonic_time(:microsecond)

      for _i <- 1..1000 do
        Solo.Telemetry.emit(:test, :event, %{}, %{})
      end

      end_time = System.monotonic_time(:microsecond)
      duration_us = end_time - start_time

      # Should complete 1000 emissions in < 1 second
      assert duration_us < 1_000_000
    end

    test "measure preserves performance characteristics", _context do
      result = Solo.Telemetry.measure(:test, :event, fn ->
        sum = Enum.sum(1..1000)
        sum
      end)

      assert result == 500_500
    end
  end
end
