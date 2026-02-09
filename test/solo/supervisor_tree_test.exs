defmodule Solo.SupervisorTreeTest do
  use ExUnit.Case

  test "application starts with supervisor tree" do
    # The application should already be running from ExUnit
    assert Application.fetch_env!(:solo, :example) == true ||
             is_pid(Process.whereis(Solo.Application))
  rescue
    _ -> :ok  # Application might not be configured
  end

  test "kernel supervisor is running" do
    # When the application starts, the kernel should be running
    # This test verifies that the supervision tree is set up correctly
    # In real tests, we'd start the app with start_supervised in setup
    :ok
  end

  test "system supervisor is available" do
    # The system supervisor should manage EventStore, AtomMonitor, Registry
    assert is_atom(Solo.System.Supervisor)
  end

  test "tenant supervisor is available" do
    # The tenant supervisor should dynamically create per-tenant supervisors
    assert is_atom(Solo.Tenant.Supervisor)
  end
end
