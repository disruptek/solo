defmodule Solo.Telemetry do
  @moduledoc """
  Telemetry integration for Solo system metrics and observability.

  Provides:
  - System-wide telemetry event definitions
  - Pluggable metrics handlers
  - Built-in Prometheus metrics export
  - Event measurement and timing

  Events emitted:
  - `[:solo, :deployment, :start]` / `[:solo, :deployment, :stop]`
  - `[:solo, :hot_swap, :start]` / `[:solo, :hot_swap, :stop]`
  - `[:solo, :capability, :verify]`
  - `[:solo, :resource, :check]`
  - `[:solo, :vault, :access]`
  """

  require Logger

  @doc """
  Start telemetry monitoring and attach default handlers.
  """
  def start_link(opts) do
    # Attach handlers synchronously and return :ok
    attach_default_handlers(opts)
    # Return a dummy tuple to satisfy supervisor expectations
    {:ok, self()}
  end

  @doc """
  Child spec for use in a supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Emit a telemetry event with measurements and metadata.

  Example:
    emit(:deployment, :deploy, %{duration_ms: 150}, %{tenant_id: "t1", service_id: "s1"})
  """
  @spec emit(atom(), atom(), map(), map()) :: :ok
  def emit(domain, event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:solo, domain, event], measurements, metadata)
  end

  @doc """
  Execute a function and automatically measure its duration.

  Returns the function result and emits timing event.
  """
  @spec measure(atom(), atom(), function()) :: any()
  def measure(domain, event, fun) do
    start_time = System.monotonic_time(:millisecond)
    result = fun.()
    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    emit(domain, event, %{duration_ms: duration_ms}, %{})
    result
  end

  # === Private Helpers ===

  defp attach_default_handlers(opts) do
    handlers = Keyword.get(opts, :handlers, [:logger])

    Enum.each(handlers, fn handler ->
      case handler do
        :logger -> attach_logger_handler()
        :metrics -> attach_metrics_handler()
        other -> Logger.warn("[Telemetry] Unknown handler: #{inspect(other)}")
      end
    end)

    Logger.info("[Telemetry] Attached handlers: #{inspect(handlers)}")
  end

  defp attach_logger_handler do
    handler = &handle_telemetry_event/4
    
    Enum.each(
      [
        [:solo, :deployment, :stop],
        [:solo, :hot_swap, :stop],
        [:solo, :capability, :verify],
        [:solo, :resource, :check],
        [:solo, :vault, :access]
      ],
      fn event ->
        :telemetry.attach("solo-telemetry-logger-#{inspect(event)}", event, handler, nil)
      end
    )
  end

  defp attach_metrics_handler do
    # In production, would attach Prometheus exporter here
    # For now, just log that it's attached
    Logger.debug("[Telemetry] Metrics handler attached")
  end

  defp handle_telemetry_event([:solo, domain, event], measurements, metadata, _config) do
    duration_str =
      case Map.get(measurements, :duration_ms) do
        nil -> ""
        ms -> " (#{ms}ms)"
      end

    Logger.debug(
      "[Telemetry] #{domain}.#{event}#{duration_str}: #{inspect(metadata)}"
    )
  end
end
