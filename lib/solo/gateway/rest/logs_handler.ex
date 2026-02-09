defmodule Solo.Gateway.REST.LogsHandler do
  @moduledoc """
  Cowboy HTTP handler for /logs endpoint.

  Supports:
  - GET /logs - Stream logs via Server-Sent Events (SSE)

  Query parameters:
  - service_id: Filter logs by service ID (optional)
  - level: Filter by log level (optional, values: DEBUG, INFO, WARN, ERROR)
  - limit: Maximum number of recent logs to start with (default: 100, max: 1000)
  """

  require Logger

  alias Solo.Gateway.REST.Helpers

  def init(req, state) do
    {:cowboy_rest, req, state}
  end

  # ===== HTTP Methods =====

  def allowed_methods(req, state) do
    {["GET", "OPTIONS"], req, state}
  end

  def options(req, state) do
    {:ok, req, state}
  end

  # ===== Content Negotiation =====

  def content_types_provided(req, state) do
    {[{"text/event-stream", :to_event_stream}], req, state}
  end

  # ===== GET /logs - Stream Logs =====

  def to_event_stream(req, state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req) do
      Helpers.log_request("GET", "/logs", tenant_id)

      # Extract query parameters
      service_id = Helpers.qs_val(req, "service_id")
      level = Helpers.qs_val(req, "level")
      limit = Helpers.qs_int(req, "limit", 100) |> min(1000)

      # Set up SSE headers
      req =
        req
        |> :cowboy_req.set_resp_header("content-type", "text/event-stream")
        |> :cowboy_req.set_resp_header("cache-control", "no-cache")
        |> :cowboy_req.set_resp_header("connection", "keep-alive")

      # Send initial response with status 200
      {:ok, req} = :cowboy_req.reply(200, %{}, "", req)

      # Send recent logs first
      send_recent_logs(req, tenant_id, service_id, level, limit)

      # Subscribe to new log events
      subscribe_to_logs(req, tenant_id, service_id, level)

      {:ok, req, state}
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, reason, req} ->
        error_response(req, 500, "internal_error", reason)
    end
  end

  # ===== Private Helpers =====

  defp send_recent_logs(req, tenant_id, service_id, level, limit) do
    # Get recent logs from EventStore
    case get_recent_logs(tenant_id, service_id, level, limit) do
      {:ok, logs} ->
        Enum.each(logs, fn log ->
          send_log_event(req, log)
        end)

      {:error, _reason} ->
        # If we can't get recent logs, just start streaming new ones
        :ok
    end
  end

  defp subscribe_to_logs(req, tenant_id, service_id, level) do
    # Subscribe to Solo.EventStore notifications
    {:ok, _} = Solo.EventStore.subscribe()

    stream_new_logs(req, tenant_id, service_id, level)
  end

  defp stream_new_logs(req, tenant_id, service_id, level) do
    receive do
      {:event, event} ->
        # Check if event matches filters
        if matches_filters?(event, tenant_id, service_id, level) do
          send_log_event(req, event)
        end

        stream_new_logs(req, tenant_id, service_id, level)

      {:EXIT, _pid, _reason} ->
        # Connection closed
        :ok

      _ ->
        stream_new_logs(req, tenant_id, service_id, level)
    after
      60000 ->
        # Send keep-alive comment every 60 seconds
        :cowboy_req.write(":\n", req)
        stream_new_logs(req, tenant_id, service_id, level)
    end
  end

  defp get_recent_logs(tenant_id, service_id, level, limit) do
    # Query EventStore for recent logs matching filters
    try do
      logs =
        Solo.EventStore.get_range(0, -limit)
        |> Enum.filter(fn event ->
          matches_filters?(event, tenant_id, service_id, level)
        end)
        |> Enum.take(limit)

      {:ok, logs}
    rescue
      _e -> {:error, "Failed to fetch recent logs"}
    end
  end

  defp matches_filters?(event, tenant_id, service_id, level_filter) do
    case event do
      %{
        "data" => %{
          "tenant_id" => event_tenant_id,
          "service_id" => event_service_id,
          "level" => event_level,
          "message" => _message
        }
      } ->
        tenant_matches = event_tenant_id == tenant_id
        service_matches = is_nil(service_id) || event_service_id == service_id
        level_matches = is_nil(level_filter) || event_level == level_filter

        tenant_matches && service_matches && level_matches

      %{
        "type" => "log",
        "tenant_id" => event_tenant_id,
        "service_id" => event_service_id,
        "level" => event_level
      } ->
        tenant_matches = event_tenant_id == tenant_id
        service_matches = is_nil(service_id) || event_service_id == service_id
        level_matches = is_nil(level_filter) || event_level == level_filter

        tenant_matches && service_matches && level_matches

      _ ->
        false
    end
  end

  defp send_log_event(req, event) do
    case format_log_event(event) do
      {:ok, json_data} ->
        # Send as Server-Sent Event
        line = "data: #{json_data}\n\n"
        :cowboy_req.write(line, req)

      {:error, _reason} ->
        # Skip malformed events
        :ok
    end
  end

  defp format_log_event(event) do
    try do
      log_data = extract_log_data(event)

      case Jason.encode(log_data) do
        {:ok, json} -> {:ok, json}
        {:error, reason} -> {:error, inspect(reason)}
      end
    rescue
      _e -> {:error, "Failed to format log event"}
    end
  end

  defp extract_log_data(event) do
    case event do
      %{
        "type" => "log",
        "timestamp" => timestamp,
        "tenant_id" => tenant_id,
        "service_id" => service_id,
        "level" => level,
        "message" => message
      } ->
        %{
          timestamp: timestamp,
          tenant_id: tenant_id,
          service_id: service_id,
          level: level,
          message: message
        }

      %{
        "data" => %{
          "timestamp" => timestamp,
          "tenant_id" => tenant_id,
          "service_id" => event_service_id,
          "level" => event_level,
          "message" => msg
        }
      } ->
        %{
          timestamp: timestamp,
          tenant_id: tenant_id,
          service_id: event_service_id,
          level: event_level,
          message: msg
        }

      _ ->
        %{
          timestamp: Helpers.current_timestamp(),
          message: inspect(event),
          level: "INFO"
        }
    end
  end

  defp error_response(req, status, error_code, message) do
    error_data = %{
      error: error_code,
      message: message,
      timestamp: Helpers.current_timestamp()
    }

    case Jason.encode(error_data) do
      {:ok, json} ->
        req
        |> :cowboy_req.set_resp_header("content-type", "application/json")
        |> :cowboy_req.reply(status, %{}, json)

      {:error, _reason} ->
        req
        |> :cowboy_req.set_resp_header("content-type", "text/plain")
        |> :cowboy_req.reply(status, %{}, "#{error_code}: #{message}")
    end
  end
end
