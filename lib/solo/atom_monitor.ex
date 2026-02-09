defmodule Solo.AtomMonitor do
  @moduledoc """
  Runtime monitoring of the atom table.

  Checks the atom count every 5 seconds and emits events at 80% and 90% thresholds.
  At 90%, logs a critical warning.

  This is a safety net for the runtime. CodeAnalyzer (Phase 8) will add static
  analysis to prevent atom table exhaustion proactively.
  """

  use GenServer

  require Logger

  @check_interval 5_000  # 5 seconds
  @threshold_80 0.80
  @threshold_90 0.90

  @doc """
  Start the AtomMonitor GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init([]) do
    Logger.info("[AtomMonitor] Started")
    # Schedule the first check
    schedule_check()
    {:ok, %{last_level: :normal}}
  end

  @impl GenServer
  def handle_info(:check_atoms, state) do
    atom_count = :erlang.system_info(:atom_count)
    atom_limit = :erlang.system_info(:atom_limit)
    usage = atom_count / atom_limit

    state =
      cond do
        usage >= @threshold_90 and state.last_level != :critical ->
          Logger.critical("[AtomMonitor] CRITICAL: Atom usage at #{percentage(usage)}% (#{atom_count}/#{atom_limit})")
          Solo.EventStore.emit(:atom_usage_high, :system, %{
            atom_count: atom_count,
            atom_limit: atom_limit,
            usage_percent: Float.round(usage * 100, 2),
            level: :critical
          })
          %{state | last_level: :critical}

        usage >= @threshold_80 and state.last_level == :normal ->
          Logger.warning("[AtomMonitor] WARNING: Atom usage at #{percentage(usage)}% (#{atom_count}/#{atom_limit})")
          Solo.EventStore.emit(:atom_usage_high, :system, %{
            atom_count: atom_count,
            atom_limit: atom_limit,
            usage_percent: Float.round(usage * 100, 2),
            level: :warning
          })
          %{state | last_level: :warning}

        usage < @threshold_80 ->
          %{state | last_level: :normal}

        true ->
          state
      end

    schedule_check()
    {:noreply, state}
  end

  # === Private Helpers ===

  defp schedule_check do
    Process.send_after(self(), :check_atoms, @check_interval)
  end

  defp percentage(fraction) do
    Float.round(fraction * 100, 2)
  end
end
