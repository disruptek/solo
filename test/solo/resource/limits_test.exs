defmodule Solo.Resource.LimitsTest do
  use ExUnit.Case

  describe "Resource.Limits.new/1" do
    test "creates limits with defaults" do
      limits = Solo.Resource.Limits.new()

      assert limits.max_memory_bytes == 50 * 1024 * 1024
      assert limits.memory_action == :warn
      assert limits.max_message_queue_len == 10_000
      assert limits.startup_timeout_ms == 5000
    end

    test "creates limits with custom values" do
      limits = Solo.Resource.Limits.new(max_memory_bytes: 100 * 1024 * 1024, memory_action: :kill)

      assert limits.max_memory_bytes == 100 * 1024 * 1024
      assert limits.memory_action == :kill
    end
  end

  describe "Resource.Limits.validate/1" do
    test "valid limits pass" do
      limits = Solo.Resource.Limits.new()
      assert :ok = Solo.Resource.Limits.validate(limits)
    end

    test "zero memory limit fails" do
      limits = Solo.Resource.Limits.new(max_memory_bytes: 0)
      assert {:error, _} = Solo.Resource.Limits.validate(limits)
    end

    test "invalid memory warning percent fails" do
      limits = Solo.Resource.Limits.new(memory_warning_percent: 101)
      assert {:error, _} = Solo.Resource.Limits.validate(limits)
    end
  end

  describe "Resource.Limits helper functions" do
    test "memory_limit_bytes returns the limit" do
      limits = Solo.Resource.Limits.new(max_memory_bytes: 100_000_000)
      assert Solo.Resource.Limits.memory_limit_bytes(limits) == 100_000_000
    end

    test "memory_warning_bytes calculates warning threshold" do
      limits = Solo.Resource.Limits.new(max_memory_bytes: 100, memory_warning_percent: 80)
      assert Solo.Resource.Limits.memory_warning_bytes(limits) == 80
    end
  end
end
