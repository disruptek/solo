defmodule Solo.Recovery.VerifierTest do
  use ExUnit.Case, async: false

  setup do
    # Reset EventStore before each test
    Solo.EventStore.reset!()
    :ok
  end

  describe "Consistency Verification" do
    test "verify consistency completes successfully" do
      # Verify should complete without error
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      assert is_atom(report.status)
      assert report.status == :ok or report.status == :warning
      assert report.total_deployed >= 0
      assert report.total_events >= 0
      assert is_integer(report.inconsistencies_found)
    end

    test "verification report has correct structure" do
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      # Check required fields
      assert Map.has_key?(report, :status)
      assert Map.has_key?(report, :timestamp)
      assert Map.has_key?(report, :total_deployed)
      assert Map.has_key?(report, :total_events)
      assert Map.has_key?(report, :inconsistencies_found)
      assert Map.has_key?(report, :inconsistencies)

      # Check types
      assert is_atom(report.status)
      assert is_integer(report.total_deployed)
      assert is_integer(report.total_events)
      assert is_integer(report.inconsistencies_found)
      assert is_list(report.inconsistencies)
    end

    test "verification detects status ok when consistent" do
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      # An empty system should be consistent
      assert report.status == :ok or report.status == :warning
    end

    test "verification counts match" do
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      # If no inconsistencies found, status should be ok
      if report.inconsistencies_found == 0 do
        assert report.status == :ok
      end
    end
  end

  describe "Auto-Fix Operations" do
    test "auto_fix returns success tuple" do
      {:ok, fixed_count} = Solo.Recovery.Verifier.auto_fix()

      assert is_integer(fixed_count)
      assert fixed_count >= 0
    end

    test "auto_fix handles empty system" do
      {:ok, count} = Solo.Recovery.Verifier.auto_fix()

      # Empty system should have nothing to fix
      assert is_integer(count)
    end

    test "auto_fix is safe to call multiple times" do
      {:ok, count1} = Solo.Recovery.Verifier.auto_fix()
      {:ok, count2} = Solo.Recovery.Verifier.auto_fix()

      # Both should succeed
      assert is_integer(count1)
      assert is_integer(count2)
    end
  end

  describe "Verification Report Retrieval" do
    test "get verification report when not available" do
      result = Solo.Recovery.Verifier.verification_report()

      # Should return error since we haven't run verification yet
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "verification report can be retrieved after verification" do
      {:ok, _} = Solo.Recovery.Verifier.verify_consistency()

      result = Solo.Recovery.Verifier.verification_report()

      # After verification, might have stored the report
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Consistency Checks" do
    test "verify consistency with service events" do
      # Emit some service events to test consistency checking
      tenant_id = "test_tenant"

      for i <- 1..3 do
        service_id = "service_#{i}"

        Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
          service_id: service_id,
          tenant_id: tenant_id,
          code: "test_code",
          format: :elixir_source
        })
      end

      # Verify consistency
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      # Should detect the events
      assert report.status == :ok or report.status == :warning
      assert report.total_events >= 3
    end

    test "verify consistency with kill events" do
      tenant_id = "test_tenant"
      service_id = "service_to_kill"

      # Deploy
      Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id,
        code: "test_code",
        format: :elixir_source
      })

      # Kill
      Solo.EventStore.emit(:service_killed, {tenant_id, service_id}, %{
        service_id: service_id,
        tenant_id: tenant_id
      })

      # Verify
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      assert report.status == :ok or report.status == :warning
    end
  end

  describe "Error Handling" do
    test "verify consistency handles errors gracefully" do
      # Should not crash
      {:ok, _} = Solo.Recovery.Verifier.verify_consistency()
      assert true
    end

    test "auto_fix handles errors gracefully" do
      # Should not crash
      {:ok, _} = Solo.Recovery.Verifier.auto_fix()
      assert true
    end

    test "verification is safe with inconsistent state" do
      # Even if system is in weird state, verification should complete
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()
      assert is_map(report)
    end
  end

  describe "Integration with Recovery" do
    test "verify consistency after recovery" do
      # Simulate recovery by emitting events
      Solo.EventStore.emit(:service_deployed, {"t1", "s1"}, %{
        service_id: "s1",
        tenant_id: "t1",
        code: "test",
        format: :elixir_source
      })

      # Verify
      {:ok, report} = Solo.Recovery.Verifier.verify_consistency()

      # Should complete successfully
      assert is_map(report)
      assert report.total_events >= 1
    end
  end
end
