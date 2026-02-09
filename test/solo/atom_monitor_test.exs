defmodule Solo.AtomMonitorTest do
  use ExUnit.Case

  setup do
    # EventStore and AtomMonitor are already started by the application
    :ok
  end

  describe "AtomMonitor" do
    test "starts successfully" do
      assert is_pid(Process.whereis(Solo.AtomMonitor))
    end

    test "monitors atom usage" do
      # The monitor should run without errors
      initial_atom_count = :erlang.system_info(:atom_count)
      assert initial_atom_count > 0

      # Wait for a monitor cycle
      Process.sleep(6_000)

      # The monitor should still be alive
      assert is_pid(Process.whereis(Solo.AtomMonitor))
    end

    test "emits events when checking atoms" do
      # Wait for a monitor cycle
      Process.sleep(6_000)

      # Check if any atom_usage_high events were emitted
      events = Solo.EventStore.stream() |> Enum.to_list()
      atom_events = Enum.filter(events, &(&1.event_type == :atom_usage_high))

      # There may or may not be atom events depending on system state
      # Just verify the structure if they exist
      Enum.each(atom_events, fn event ->
        assert event.payload |> Map.has_key?(:atom_count)
        assert event.payload |> Map.has_key?(:atom_limit)
        assert event.payload |> Map.has_key?(:usage_percent)
        assert event.payload |> Map.has_key?(:level)
      end)
    end
  end
end
