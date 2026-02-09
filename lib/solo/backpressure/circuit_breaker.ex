defmodule Solo.Backpressure.CircuitBreaker do
  @moduledoc """
  Circuit breaker for per-service call protection.

  Prevents cascading failures by stopping calls to services that are
  repeatedly failing. Transitions through three states:

  - `:closed` - normal operation, calls pass through
  - `:open` - too many failures, calls rejected with :circuit_breaker_open
  - `:half_open` - testing if service recovered, limited calls allowed

  Configuration:
  - `failure_threshold`: Number of failures before opening
  - `reset_timeout_ms`: How long to stay open before trying half-open
  - `success_threshold`: How many successes in half-open before closing
  """

  use GenServer

  require Logger

  @doc """
  Start a circuit breaker for a service.

  Options:
  - `tenant_id`: The tenant owning the service
  - `service_id`: The service being protected
  - `failure_threshold`: Failures before opening (default 5)
  - `reset_timeout_ms`: Time in open state (default 30000)
  - `success_threshold`: Successes in half-open before closing (default 2)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Call through the circuit breaker.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure/open.
  """
  @spec call(pid(), (() -> any()), non_neg_integer()) :: {:ok, any()} | {:error, atom()}
  def call(breaker_pid, fun, timeout_ms \\ 5000) when is_function(fun, 0) do
    GenServer.call(breaker_pid, {:call, fun, timeout_ms}, timeout_ms + 1000)
  end

  @doc """
  Get the current state of the circuit breaker.
  """
  @spec state(pid()) :: :closed | :open | :half_open
  def state(breaker_pid) do
    GenServer.call(breaker_pid, :state)
  end

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    service_id = Keyword.fetch!(opts, :service_id)
    failure_threshold = Keyword.get(opts, :failure_threshold, 5)
    reset_timeout_ms = Keyword.get(opts, :reset_timeout_ms, 30_000)
    success_threshold = Keyword.get(opts, :success_threshold, 2)

    Logger.debug("[CircuitBreaker] Started for #{tenant_id}/#{service_id}")

    {:ok,
     %{
       tenant_id: tenant_id,
       service_id: service_id,
       state: :closed,
       failure_count: 0,
       success_count: 0,
       failure_threshold: failure_threshold,
       reset_timeout_ms: reset_timeout_ms,
       success_threshold: success_threshold,
       last_error: nil,
       last_error_time: nil
     }}
  end

  @impl GenServer
  def handle_call({:call, fun, timeout_ms}, _from, state) do
    case state.state do
      :closed ->
        call_closed(fun, timeout_ms, state)

      :open ->
        # Check if we should transition to half-open
        if should_attempt_reset?(state) do
          call_half_open(fun, timeout_ms, %{state | state: :half_open, success_count: 0})
        else
          {:reply, {:error, :circuit_breaker_open}, state}
        end

      :half_open ->
        call_half_open(fun, timeout_ms, state)
    end
  end

  def handle_call(:state, _from, state) do
    {:reply, state.state, state}
  end

  @impl GenServer
  def handle_info(:reset_timer, state) do
    if state.state == :open do
      Logger.info(
        "[CircuitBreaker] Reset timer expired for #{state.tenant_id}/#{state.service_id}, attempting half-open"
      )
    end

    {:noreply, state}
  end

  # === Private Helpers ===

  defp call_closed(fun, timeout_ms, state) do
    case safe_call(fun, timeout_ms) do
      {:ok, result} ->
        {:reply, {:ok, result}, %{state | failure_count: 0}}

      {:error, reason} ->
        failure_count = state.failure_count + 1

        if failure_count >= state.failure_threshold do
          Logger.warning(
            "[CircuitBreaker] #{state.service_id} failure threshold reached, opening circuit"
          )

          Solo.EventStore.emit(:circuit_breaker_opened, {state.tenant_id, state.service_id}, %{
            reason: inspect(reason),
            tenant_id: state.tenant_id,
            service_id: state.service_id
          })

          schedule_reset(state.reset_timeout_ms)

          {:reply, {:error, reason},
           %{
             state
             | state: :open,
               failure_count: failure_count,
               last_error: reason,
               last_error_time: System.system_time(:millisecond)
           }}
        else
          {:reply, {:error, reason}, %{state | failure_count: failure_count}}
        end
    end
  end

  defp call_half_open(fun, timeout_ms, state) do
    case safe_call(fun, timeout_ms) do
      {:ok, result} ->
        success_count = state.success_count + 1

        if success_count >= state.success_threshold do
          Logger.info(
            "[CircuitBreaker] #{state.service_id} recovered, closing circuit"
          )

          Solo.EventStore.emit(:circuit_breaker_closed, {state.tenant_id, state.service_id}, %{
            tenant_id: state.tenant_id,
            service_id: state.service_id
          })

          {:reply, {:ok, result},
           %{state | state: :closed, failure_count: 0, success_count: 0}}
        else
          {:reply, {:ok, result}, %{state | success_count: success_count}}
        end

      {:error, reason} ->
        Logger.warning(
          "[CircuitBreaker] #{state.service_id} failed in half-open, reopening circuit"
        )

        schedule_reset(state.reset_timeout_ms)

        {:reply, {:error, reason},
         %{
           state
           | state: :open,
             failure_count: 0,
             success_count: 0,
             last_error: reason,
             last_error_time: System.system_time(:millisecond)
         }}
    end
  end

  defp safe_call(fun, timeout_ms) do
    try do
      {:ok, fun.()}
    catch
      :exit, reason ->
        {:error, {:exit, reason}}

      kind, value ->
        {:error, {kind, value}}
    rescue
      e ->
        {:error, e}
    end
  end

  defp should_attempt_reset?(state) do
    case state.last_error_time do
      nil ->
        true

      last_time ->
        elapsed = System.system_time(:millisecond) - last_time
        elapsed >= state.reset_timeout_ms
    end
  end

  defp schedule_reset(timeout_ms) do
    Process.send_after(self(), :reset_timer, timeout_ms)
  end
end
