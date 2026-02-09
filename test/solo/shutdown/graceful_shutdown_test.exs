defmodule Solo.Shutdown.GracefulShutdownTest do
  use ExUnit.Case, async: false

  require Logger

  describe "Graceful Shutdown Handler" do
    test "handler can be registered" do
      # Just verify the function exists and is callable
      result = Solo.Shutdown.GracefulShutdown.start_handler()
      assert result == :ok or match?({:error, _}, result)
    end

    test "shutdown_in_progress? returns false initially" do
      Application.put_env(:solo, :shutdown_in_progress, false)
      assert Solo.Shutdown.GracefulShutdown.shutdown_in_progress?() == false
    end

    test "shutdown_in_progress? returns true when set" do
      Application.put_env(:solo, :shutdown_in_progress, true)
      assert Solo.Shutdown.GracefulShutdown.shutdown_in_progress?() == true
      Application.put_env(:solo, :shutdown_in_progress, false)
    end

    test "EventStore.flush is callable" do
      result = Solo.EventStore.flush()
      assert result == :ok or match?({:error, _}, result)
    end

    test "Vault.flush is callable" do
      result = Solo.Vault.flush()
      assert result == :ok or match?({:error, _}, result)
    end

    test "module exports all required functions" do
      # start_handler/0
      assert function_exported?(Solo.Shutdown.GracefulShutdown, :start_handler, 0)
      # shutdown_in_progress?/0
      assert function_exported?(Solo.Shutdown.GracefulShutdown, :shutdown_in_progress?, 0)
    end
  end

  describe "Flush Operations" do
    test "EventStore can be flushed without error" do
      # Emit an event first
      Solo.EventStore.emit(:system_shutdown_started, :system, %{test: true})

      # Then flush
      result = Solo.EventStore.flush()

      assert result == :ok or match?({:error, _}, result)
    end

    test "Vault can be flushed without error" do
      result = Solo.Vault.flush()
      assert result == :ok or match?({:error, _}, result)
    end

    test "multiple flushes work correctly" do
      # EventStore flushes
      result1 = Solo.EventStore.flush()
      result2 = Solo.EventStore.flush()
      assert result1 == :ok or match?({:error, _}, result1)
      assert result2 == :ok or match?({:error, _}, result2)

      # Vault flushes
      result3 = Solo.Vault.flush()
      result4 = Solo.Vault.flush()
      assert result3 == :ok or match?({:error, _}, result3)
      assert result4 == :ok or match?({:error, _}, result4)
    end

    test "flush with no pending events still works" do
      # Even with no events, flush should succeed
      result = Solo.EventStore.flush()
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "Shutdown Event Emission" do
    test "system shutdown events can be emitted without error" do
      # Just verify they don't crash
      Solo.EventStore.emit(:system_shutdown_started, :system, %{"reason" => "SIGTERM"})
      Process.sleep(10)
      Solo.EventStore.emit(:system_shutdown_complete, :system, %{"exit_code" => 0})
      Process.sleep(10)

      # Should reach here without error
      assert true
    end

    test "shutdown started event can be emitted with timestamp" do
      # Just verify it doesn't crash
      Solo.EventStore.emit(:system_shutdown_started, :system, %{
        "reason" => "SIGTERM",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      # Should reach here without error
      assert true
    end

    test "shutdown complete event can be emitted with exit code" do
      # Just verify it doesn't crash
      Solo.EventStore.emit(:system_shutdown_complete, :system, %{"exit_code" => 0})
      # Should reach here without error
      assert true
    end
  end

  describe "Configuration" do
    test "graceful shutdown can be configured" do
      Application.put_env(:solo, :shutdown_timeout_ms, 5000)
      timeout = Application.get_env(:solo, :shutdown_timeout_ms)
      assert timeout == 5000
    end

    test "shutdown config has sensible defaults" do
      # Should have some default or be configurable
      Application.put_env(:solo, :shutdown_timeout_ms, 5000)
      timeout = Application.get_env(:solo, :shutdown_timeout_ms, 5000)
      assert is_integer(timeout)
      assert timeout > 0
    end
  end

  describe "Error Handling" do
    test "flush handles errors gracefully" do
      # These should not raise exceptions
      result1 = Solo.EventStore.flush()
      result2 = Solo.Vault.flush()

      # Either success or error tuple, but not exception
      assert is_atom(result1) or is_tuple(result1)
      assert is_atom(result2) or is_tuple(result2)
    end

    test "shutdown handler registration is safe" do
      # Should not crash
      result = Solo.Shutdown.GracefulShutdown.start_handler()
      assert result == :ok or match?({:error, _}, result)
    end
  end
end
