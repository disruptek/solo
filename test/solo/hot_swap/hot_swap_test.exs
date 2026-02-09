defmodule Solo.HotSwap.HotSwapTest do
  use ExUnit.Case, async: false
  doctest Solo.HotSwap

  setup do
    # Start a clean system for each test
    {:ok, _apps} = Application.ensure_all_started(:solo)
    Solo.EventStore.reset!()

    {:ok,
     tenant_id: "test_tenant_1",
     service_id: "test_service_1"}
  end

  # Helper to generate valid test service code
  defp test_service_code(version \\ 1) do
    """
    defmodule TestService do
      use GenServer

      def start_link(_opts) do
        GenServer.start_link(__MODULE__, nil)
      end

      def init(_), do: {:ok, %{version: #{version}}}
    end
    """
  end

  describe "swap/4 - hot code replacement" do
    test "performs a hot swap of running service code", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      # Deploy initial service
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(1),
          format: :elixir_source
        })

      # Verify initial deployment worked
      [{pid, _}] = Solo.Registry.lookup(tenant_id, service_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Perform hot swap
      result = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(2))
      assert result == :ok

      # Verify events were emitted
      events = Solo.EventStore.filter(event_type: :hot_swap_started)
      assert length(events) >= 1

      # Verify service still exists
      [{new_pid, _}] = Solo.Registry.lookup(tenant_id, service_id)
      assert is_pid(new_pid)
      assert Process.alive?(new_pid)
    end

    test "fails gracefully when service not found", %{tenant_id: tenant_id} do
      result = Solo.HotSwap.swap(tenant_id, "nonexistent_service", test_service_code())

      assert {:error, _reason} = result
    end

    test "fails gracefully on compilation error", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      # Deploy initial service
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      # Try to swap with invalid code
      invalid_code = "defmodule TestService do this is invalid syntax"

      result = Solo.HotSwap.swap(tenant_id, service_id, invalid_code)

      assert {:error, _reason} = result

      # Verify hot_swap_failed event was emitted
      events = Solo.EventStore.filter(event_type: :hot_swap_failed)
      assert length(events) >= 1
    end

    test "emits hot_swap_started event", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      _result = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(2))

      events = Solo.EventStore.filter(event_type: :hot_swap_started)
      assert length(events) >= 1
    end

    test "respects custom rollback window", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      # Swap with custom window
      result = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(2), rollback_window_ms: 5000)

      assert result == :ok
    end
  end

  describe "replace/4 - simple stop and redeploy" do
    test "kills and redeploys a service", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, pid1} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(1),
          format: :elixir_source
        })

      assert Process.alive?(pid1)

      # Perform simple replace
      {:ok, pid2} = Solo.HotSwap.replace(tenant_id, service_id, test_service_code(2))

      # Verify new service is different PID
      assert is_pid(pid2)
      assert pid1 != pid2
      assert Process.alive?(pid2)
      refute Process.alive?(pid1)
    end

    test "fails when kill fails", %{
      tenant_id: tenant_id
    } do
      # Try to replace non-existent service
      result = Solo.HotSwap.replace(tenant_id, "nonexistent", test_service_code())

      assert {:error, _reason} = result
    end

    test "emits hot_swap_succeeded event for simple replace", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      {:ok, _new_pid} = Solo.HotSwap.replace(tenant_id, service_id, test_service_code(2))

      events = Solo.EventStore.filter(event_type: :hot_swap_succeeded)
      assert length(events) >= 1
    end
  end

  describe "watchdog monitoring" do
    test "watchdog emits hot_swap_succeeded when service survives window", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      # Swap with short rollback window
      :ok = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(2), rollback_window_ms: 100)

      # Wait for watchdog to complete
      Process.sleep(200)

      # Verify hot_swap_succeeded was emitted (by watchdog timeout)
      events = Solo.EventStore.filter(event_type: :hot_swap_succeeded)

      # Should have at least one hot_swap_succeeded event
      assert length(events) >= 1
    end

    test "service can be swapped multiple times", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(1),
          format: :elixir_source
        })

      # First swap
      result1 = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(2), rollback_window_ms: 100)
      assert result1 == :ok

      Process.sleep(150)

      # Second swap
      result2 = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(3), rollback_window_ms: 100)
      assert result2 == :ok

      Process.sleep(150)

      # Verify service still running
      [{pid, _}] = Solo.Registry.lookup(tenant_id, service_id)
      assert Process.alive?(pid)

      # Count successful swaps
      events = Solo.EventStore.filter(event_type: :hot_swap_succeeded)
      assert length(events) >= 2
    end
  end

  describe "event emission" do
    test "emits correct events for successful swap", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      :ok = Solo.HotSwap.swap(tenant_id, service_id, test_service_code(2), rollback_window_ms: 100)

      Process.sleep(150)

      # Check for hot_swap_started
      started_events = Solo.EventStore.filter(event_type: :hot_swap_started)
      assert length(started_events) >= 1

      # Check for hot_swap_succeeded (from watchdog)
      succeeded_events = Solo.EventStore.filter(event_type: :hot_swap_succeeded)
      assert length(succeeded_events) >= 1
    end

    test "emits hot_swap_failed for failed swap", %{
      tenant_id: tenant_id,
      service_id: service_id
    } do
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_id,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      invalid_code = "defmodule TestService do bad syntax"
      {:error, _} = Solo.HotSwap.swap(tenant_id, service_id, invalid_code)

      # Check for hot_swap_failed
      failed_events = Solo.EventStore.filter(event_type: :hot_swap_failed)
      assert length(failed_events) >= 1
    end
  end

  describe "isolation between tenants" do
    test "cannot swap service from another tenant" do
      tenant_1 = "tenant_iso_1"
      tenant_2 = "tenant_iso_2"
      service_id = "iso_service"

      # Deploy to tenant_1
      {:ok, _pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_1,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      # Try to swap from tenant_2
      result = Solo.HotSwap.swap(tenant_2, service_id, test_service_code(2))

      assert {:error, _} = result
    end

    test "services from different tenants have independent swap windows" do
      tenant_1 = "tenant_wind_1"
      tenant_2 = "tenant_wind_2"
      service_id = "wind_service"

      # Deploy to both tenants
      {:ok, _pid1} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_1,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      {:ok, _pid2} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: tenant_2,
          service_id: service_id,
          code: test_service_code(),
          format: :elixir_source
        })

      # Swap both
      :ok = Solo.HotSwap.swap(tenant_1, service_id, test_service_code(2), rollback_window_ms: 100)
      :ok = Solo.HotSwap.swap(tenant_2, service_id, test_service_code(2), rollback_window_ms: 100)

      Process.sleep(150)

      # Both should have succeeded independently
      events = Solo.EventStore.filter(event_type: :hot_swap_succeeded)
      assert length(events) >= 2
    end
  end
end
