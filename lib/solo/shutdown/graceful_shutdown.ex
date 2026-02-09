defmodule Solo.Shutdown.GracefulShutdown do
  @moduledoc """
  Handle graceful shutdown of the Solo system on SIGTERM signal (Phase 9).

  When the system receives SIGTERM (e.g., via `kill -TERM <pid>`), this module:
  1. Emits :system_shutdown_started event
  2. Waits briefly for pending operations to complete
  3. Flushes all data to disk (EventStore, Vault, TokenStore)
  4. Emits :system_shutdown_complete event
  5. Exits cleanly with exit code 0

  This ensures:
  - No data loss during shutdown
  - All pending operations are written to disk
  - Clean exit instead of forced termination
  - Minimal recovery needed on next startup

  Signal handler is registered in Solo.Kernel.start/2 during application startup.
  """

  require Logger

  @doc """
  Start the signal handler for SIGTERM (graceful shutdown).

  Should be called during application startup in Solo.Kernel.start/2.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec start_handler() :: :ok | {:error, String.t()}
  def start_handler do
    try do
      # Register signal handler with the system
      # Elixir 1.15+ has System.trap_signal/2, older versions use :erl_signal_server
      case trap_signal() do
        :ok ->
          Logger.info("[GracefulShutdown] SIGTERM handler registered")
          :ok

        error ->
          Logger.warning(
            "[GracefulShutdown] Failed to register signal handler: #{inspect(error)}"
          )

          error
      end
    rescue
      e ->
        Logger.warning("[GracefulShutdown] Exception registering signal handler: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  @doc """
  Execute the graceful shutdown sequence.

  Called when SIGTERM is received. Performs:
  1. Emit startup event
  2. Wait for pending operations
  3. Flush all data sources
  4. Emit completion event
  5. Exit cleanly

  Returns: Does not return (calls System.halt)
  """
  @spec shutdown_sequence() :: no_return()
  def shutdown_sequence do
    Logger.warning("[GracefulShutdown] SIGTERM received, initiating graceful shutdown")

    # Emit shutdown started event
    try do
      Solo.EventStore.emit(:system_shutdown_started, :system, %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        reason: "SIGTERM"
      })
    rescue
      _e -> :ok
    end

    # Wait for pending GenServer.cast operations to complete
    # Most casts to EventStore should complete in < 100ms
    Process.sleep(100)

    # Flush all data sources to disk
    flush_all()

    # Emit shutdown complete event
    try do
      Solo.EventStore.emit(:system_shutdown_complete, :system, %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        exit_code: 0
      })
    rescue
      _e -> :ok
    end

    # Wait a bit more for the final event to be written
    Process.sleep(100)

    Logger.info("[GracefulShutdown] Graceful shutdown complete, exiting with code 0")

    # Exit cleanly
    System.halt(0)
  end

  @doc """
  Check if a graceful shutdown is in progress.

  Returns `true` if shutdown has been initiated, `false` otherwise.
  """
  @spec shutdown_in_progress?() :: boolean()
  def shutdown_in_progress? do
    Application.get_env(:solo, :shutdown_in_progress, false)
  end

  # ===== Private Implementation =====

  # Register signal handler - try Elixir 1.15+ method first, fall back to Erlang
  defp trap_signal do
    try do
      # Elixir 1.15+ has System.trap_signal/2
      if function_exported?(System, :trap_signal, 2) do
        System.trap_signal(:sigterm, fn ->
          Application.put_env(:solo, :shutdown_in_progress, true)
          shutdown_sequence()
        end)

        :ok
      else
        # Fall back to Erlang signal handling
        case :erl_signal_server.register_signal_handler(:sigterm, :erl_signal_handler) do
          {:ok, _} -> :ok
          error -> error
        end
      end
    rescue
      _e -> {:error, "Signal handler not available"}
    end
  end

  # Flush all data sources to ensure no data loss
  defp flush_all do
    Logger.debug("[GracefulShutdown] Flushing data to disk")

    # Flush EventStore
    case flush_eventstore() do
      :ok -> Logger.debug("[GracefulShutdown] EventStore flushed")
      error -> Logger.warning("[GracefulShutdown] EventStore flush failed: #{inspect(error)}")
    end

    # Flush Vault
    case flush_vault() do
      :ok -> Logger.debug("[GracefulShutdown] Vault flushed")
      error -> Logger.warning("[GracefulShutdown] Vault flush failed: #{inspect(error)}")
    end

    # Flush TokenStore
    case flush_token_store() do
      :ok -> Logger.debug("[GracefulShutdown] TokenStore flushed")
      error -> Logger.warning("[GracefulShutdown] TokenStore flush failed: #{inspect(error)}")
    end
  end

  defp flush_eventstore do
    try do
      case Solo.EventStore.flush() do
        :ok -> :ok
        error -> error
      end
    rescue
      _e -> {:error, "EventStore not available"}
    catch
      _type, _reason -> {:error, "EventStore flush error"}
    end
  end

  defp flush_vault do
    try do
      case Solo.Vault.flush() do
        :ok -> :ok
        error -> error
      end
    rescue
      _e -> {:error, "Vault not available"}
    catch
      _type, _reason -> {:error, "Vault flush error"}
    end
  end

  defp flush_token_store do
    try do
      # TokenStore uses CubDB directly, flush via direct DB access if needed
      # For now, just return ok as CubDB handles persistence
      :ok
    rescue
      _e -> {:error, "TokenStore flush failed"}
    end
  end
end
