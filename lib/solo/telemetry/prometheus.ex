defmodule Solo.Telemetry.Prometheus do
  @moduledoc """
  Prometheus metrics and health checks for Solo.

  Provides:
  - Health check status endpoint
  - Metrics collection points
  """

  require Logger

  @doc """
  Get health status of all Solo services.
  Returns a map suitable for JSON serialization.
  """
  def health_status do
    %{
      status: "healthy",
      timestamp: System.os_time(:millisecond),
      version: "0.2.0",
      uptime_ms: get_uptime_ms(),
      memory_mb: get_memory_mb(),
      process_count: get_process_count()
    }
  end

  @doc """
  Record a deployment event for metrics.
  """
  def record_deployment(tenant_id, service_id, success, duration_ms) do
    event_type = if success, do: :deployment_success, else: :deployment_failure

    :telemetry.execute(
      [:solo, :deployment, event_type],
      %{
        duration_ms: duration_ms,
        timestamp: System.os_time(:millisecond)
      },
      %{
        tenant_id: tenant_id,
        service_id: service_id
      }
    )
  end

  @doc """
  Record a service kill event.
  """
  def record_service_kill(tenant_id, service_id) do
    :telemetry.execute(
      [:solo, :service, :killed],
      %{
        timestamp: System.os_time(:millisecond)
      },
      %{
        tenant_id: tenant_id,
        service_id: service_id
      }
    )
  end

  @doc """
  Record service status check.
  """
  def record_status_check(tenant_id, service_id, alive?, memory_bytes) do
    :telemetry.execute(
      [:solo, :service, :status],
      %{
        timestamp: System.os_time(:millisecond),
        memory_bytes: memory_bytes,
        alive: alive?
      },
      %{
        tenant_id: tenant_id,
        service_id: service_id
      }
    )
  end

  @doc """
  Get current metrics summary.
  """
  def get_metrics do
    %{
      timestamp: System.os_time(:millisecond),
      uptime_ms: get_uptime_ms(),
      memory_mb: get_memory_mb(),
      process_count: get_process_count()
    }
  end

  # === Private Helpers ===

  defp get_uptime_ms do
    case :erlang.statistics(:wall_clock) do
      {total, _} -> total
      _ -> 0
    end
  end

  defp get_memory_mb do
    case :erlang.memory(:total) do
      total when is_integer(total) -> div(total, 1024 * 1024)
      _ -> 0
    end
  end

  defp get_process_count do
    case :erlang.system_info(:process_count) do
      count when is_integer(count) -> count
      _ -> 0
    end
  end
end
