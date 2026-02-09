defmodule Solo.Recovery.ReplayerTest do
  use ExUnit.Case, async: false

  setup do
    # Reset EventStore before each test
    Solo.EventStore.reset!()
    :ok
  end

  @service_code """
  defmodule TestService do
    def start_link(_opts) do
      {:ok, self()}
    end
  end
  """

  describe "Event Replay Recovery" do
    test "detect single service deployment event" do
      tenant_id = "test_tenant"
      service_id = "test_service"

      # Emit a service deployment event
      Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id,
        code: @service_code,
        format: :elixir_source,
        restart_limits: %{max_restarts: 5, max_seconds: 60}
      })

      # Run recovery (via direct function call)
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      # Verify structure
      assert report.status == :success
      assert is_map(report)
      assert is_integer(report.recovered_count)
      assert is_integer(report.skipped_count)
      assert is_integer(report.failed_count)
      assert is_list(report.services)
    end

    test "detect multiple service deployments" do
      tenant_id = "tenant_a"

      # Deploy 5 services
      for i <- 1..5 do
        service_id = "service_#{i}"

        Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
          service_id: service_id,
          tenant_id: tenant_id,
          code: @service_code,
          format: :elixir_source,
          restart_limits: %{max_restarts: 5, max_seconds: 60}
        })
      end

      # Run recovery
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      # Verify all deployments are detected
      assert report.status == :success
      assert length(report.services) >= 5
    end

    test "skip killed services from recovery" do
      tenant_id = "tenant_b"
      service_id = "service_to_kill"

      # Deploy service
      Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id,
        code: @service_code,
        format: :elixir_source,
        restart_limits: %{max_restarts: 5, max_seconds: 60}
      })

      # Kill it
      Solo.EventStore.emit(:service_killed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id
      })

      # Run recovery
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      # Verify service is marked as skipped
      assert report.status == :success
      assert report.skipped_count >= 1
    end

    test "handle no new events in clean test" do
      # Get current event count
      events_before = Solo.EventStore.filter() |> length()

      # Run recovery
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      # Verify recovery completed successfully
      assert report.status == :success
      assert is_integer(report.recovered_count)
      assert is_integer(report.skipped_count)
    end

    test "recovery is idempotent" do
      tenant_id = "tenant_c"
      service_id = "service_idempotent"

      # Emit deployment event
      Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id,
        code: @service_code,
        format: :elixir_source,
        restart_limits: %{max_restarts: 5, max_seconds: 60}
      })

      # Run recovery twice
      {:ok, report1} = Solo.Recovery.Replayer.execute_recovery()
      {:ok, report2} = Solo.Recovery.Replayer.execute_recovery()

      # Both should have same status
      assert report1.status == report2.status
      assert length(report1.services) == length(report2.services)
    end

    test "mixed deployed and killed services" do
      tenant_id = "tenant_d"

      # Deploy 3 services
      for i <- 1..3 do
        service_id = "service_#{i}"

        Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
          service_id: service_id,
          tenant_id: tenant_id,
          code: @service_code,
          format: :elixir_source,
          restart_limits: %{max_restarts: 5, max_seconds: 60}
        })
      end

      # Kill service 1 and 2
      for i <- 1..2 do
        service_id = "service_#{i}"

        Solo.EventStore.emit(:service_killed, {tenant_id, service_id}, %{
          service_id: service_id,
          tenant_id: tenant_id
        })
      end

      # Run recovery
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      assert report.status == :success
      assert report.skipped_count >= 2
      assert length(report.services) >= 3
    end

    test "multiple tenants recovery" do
      # Deploy services for tenant A
      for i <- 1..2 do
        Solo.EventStore.emit(:service_deployed, {"tenant_a", "service_a_#{i}"}, %{
          service_id: "service_a_#{i}",
          tenant_id: "tenant_a",
          code: @service_code,
          format: :elixir_source,
          restart_limits: %{max_restarts: 5, max_seconds: 60}
        })
      end

      # Deploy services for tenant B
      for i <- 1..3 do
        Solo.EventStore.emit(:service_deployed, {"tenant_b", "service_b_#{i}"}, %{
          service_id: "service_b_#{i}",
          tenant_id: "tenant_b",
          code: @service_code,
          format: :elixir_source,
          restart_limits: %{max_restarts: 5, max_seconds: 60}
        })
      end

      # Run recovery
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      assert report.status == :success
      assert length(report.services) >= 5
    end

    test "recovery report has correct structure" do
      Solo.EventStore.emit(:service_deployed, {"test", "svc"}, %{
        service_id: "svc",
        tenant_id: "test",
        code: @service_code,
        format: :elixir_source,
        restart_limits: %{max_restarts: 5, max_seconds: 60}
      })

      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()

      assert Map.has_key?(report, :status)
      assert Map.has_key?(report, :timestamp)
      assert Map.has_key?(report, :recovered_count)
      assert Map.has_key?(report, :skipped_count)
      assert Map.has_key?(report, :failed_count)
      assert Map.has_key?(report, :services)
      assert is_list(report.services)
      assert is_integer(report.recovered_count)
      assert is_integer(report.skipped_count)
      assert is_integer(report.failed_count)
    end

    test "recovery detects services with full event payload" do
      payload = %{
        service_id: "test",
        tenant_id: "tenant",
        code: @service_code,
        format: :elixir_source,
        restart_limits: %{max_restarts: 5, max_seconds: 60}
      }

      Solo.EventStore.emit(:service_deployed, {"tenant", "test"}, payload)

      # Recovery should be able to detect this
      {:ok, report} = Solo.Recovery.Replayer.execute_recovery()
      assert report.status == :success
    end
  end
end
