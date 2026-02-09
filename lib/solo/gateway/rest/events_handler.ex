defmodule Solo.Gateway.REST.EventsHandler do
  @moduledoc """
  Cowboy HTTP handler for /events endpoint (Server-Sent Events).

  Provides real-time event streaming to HTTP clients via Server-Sent Events (SSE).

  Query parameters:
  - service_id: Filter by service ID (optional)
  - since_id: Stream events after this ID (default: 0)
  - include_logs: Include verbose logging events (default: false)
  """

  require Logger

  alias Solo.Gateway.REST.Helpers

  def init(req, state) do
    {:cowboy_loop, req, state, :hibernate}
  end

  def handle(req, state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req) do
      Helpers.log_request("GET", "/events", tenant_id)

      # Get query parameters
      service_id = Helpers.qs_val(req, "service_id", "")
      since_id = Helpers.qs_int(req, "since_id", 0)
      include_logs = Helpers.qs_bool(req, "include_logs", false)

      # Set up SSE response headers
      req = :cowboy_req.set_resp_header("content-type", "text/event-stream", req)
      req = :cowboy_req.set_resp_header("cache-control", "no-cache", req)
      req = :cowboy_req.set_resp_header("connection", "keep-alive", req)
      req = :cowboy_req.set_resp_header("x-accel-buffering", "no", req)

      # Send response status
      {:ok, req} = :cowboy_req.send_resp(200, %{}, req)

      # Stream events to client
      stream_events(req, state, tenant_id, service_id, since_id, include_logs)
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, reason, req} ->
        Helpers.error_response(req, 500, "internal_error", reason)
    end
  end

  def terminate(_reason, _req, _state) do
    :ok
  end

  # ===== Private Helpers =====

  defp stream_events(req, state, tenant_id, service_id, since_id, include_logs) do
    Logger.info(
      "[Gateway REST] Events stream started: #{tenant_id}, " <>
        "service_id: #{service_id}, since_id: #{since_id}"
    )

    # Get event stream from event store
    case create_event_stream(tenant_id, service_id, since_id, include_logs) do
      events when is_list(events) ->
        # Send each event to the client
        Enum.each(events, fn event ->
          send_event(req, event)
          # Small delay to prevent overwhelming client
          Process.sleep(10)
        end)

        Logger.info("[Gateway REST] Events stream completed for #{tenant_id}")
        {:ok, req, state}

      _error ->
        Logger.warning("[Gateway REST] Failed to get event stream for #{tenant_id}")
        {:ok, req, state}
    end
  rescue
    e ->
      Logger.error("[Gateway REST] Event streaming error: #{inspect(e)}")
      {:ok, req, state}
  end

  defp create_event_stream(tenant_id, service_id, since_id, include_logs) do
    case service_id do
      "" ->
        # Stream all events for the tenant
        Solo.EventStore.stream(tenant_id: tenant_id, since_id: since_id)

      _ ->
        # Stream events for a specific service
        Solo.EventStore.stream(tenant_id: tenant_id, service_id: service_id, since_id: since_id)
    end
    |> filter_events(include_logs)
  rescue
    _e ->
      []
  end

  defp filter_events(events, include_logs) do
    if include_logs do
      events
    else
      # Filter out verbose logging events
      case events do
        list when is_list(list) ->
          Enum.filter(list, fn event ->
            event.event_type not in [:service_log, :metric_recorded, :debug]
          end)

        _other ->
          []
      end
    end
  end

  defp send_event(req, event) do
    event_json = encode_event(event)
    sse_frame = "data: #{event_json}\n\n"

    case :cowboy_req.send_chunk(sse_frame, req) do
      {:ok, _req} ->
        Logger.debug("[Gateway REST] Event sent: #{event.id}")

      {:error, closed} ->
        Logger.info("[Gateway REST] Client closed connection: #{closed}")
        throw(:client_closed)

      {:error, reason} ->
        Logger.warning("[Gateway REST] Failed to send event: #{inspect(reason)}")
        throw(:send_failed)
    end
  end

  defp encode_event(event) do
    event_map = %{
      id: event.id,
      event_type: to_string(event.event_type),
      timestamp: Helpers.format_timestamp(event.wall_clock),
      payload: event.payload
    }

    # Add service_id if available in subject
    event_map =
      case event.subject do
        {_tenant_id, service_id} ->
          Map.put(event_map, :service_id, service_id)

        service_id when is_binary(service_id) ->
          Map.put(event_map, :service_id, service_id)

        _ ->
          event_map
      end

    # Add tenant_id if available
    event_map =
      if event.tenant_id do
        Map.put(event_map, :tenant_id, event.tenant_id)
      else
        event_map
      end

    case Jason.encode(event_map) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end
end
