defmodule Solo.Gateway.REST.ServiceHandler do
  @moduledoc """
  Cowboy HTTP handler for /services/{service_id} endpoint.

  Supports:
  - GET /services/{service_id} - Get service status
  - DELETE /services/{service_id} - Kill a service
  """

  require Logger

  alias Solo.Gateway.REST.Helpers

  def init(req, state) do
    {:cowboy_rest, req, state}
  end

  # ===== HTTP Methods =====

  def allowed_methods(req, state) do
    {["GET", "DELETE", "OPTIONS"], req, state}
  end

  def options(req, state) do
    {:ok, req, state}
  end

  # ===== Content Negotiation =====

  def content_types_provided(req, state) do
    {[{"application/json", :to_json}], req, state}
  end

  # ===== GET /services/{service_id} - Get Service Status =====

  def to_json(req, state) do
    service_id = :cowboy_req.binding(:service_id, req)

    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req),
         :ok <- Helpers.validate_service_id(service_id),
         {:ok, status_data} <- get_service_status(tenant_id, service_id) do
      Helpers.log_request("GET", "/services/#{service_id}", tenant_id)
      Helpers.json_response(req, 200, status_data)
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, "Invalid service_id format"} ->
        Helpers.error_response(
          req,
          400,
          "invalid_service_id",
          "Service ID contains invalid characters"
        )

      {:error, :not_found} ->
        Helpers.error_response(req, 404, "not_found", "Service '#{service_id}' not found")

      {:error, reason} ->
        Helpers.error_response(req, 500, "internal_error", inspect(reason))
    end
  end

  # ===== DELETE /services/{service_id} - Kill Service =====

  def delete_resource(req, state) do
    service_id = :cowboy_req.binding(:service_id, req)

    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req),
         :ok <- Helpers.validate_service_id(service_id),
         {:ok, response_data} <- kill_service(tenant_id, service_id, req) do
      Helpers.log_request("DELETE", "/services/#{service_id}", tenant_id)
      Helpers.json_response(req, 202, response_data)
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, "Invalid service_id format"} ->
        Helpers.error_response(
          req,
          400,
          "invalid_service_id",
          "Service ID contains invalid characters"
        )

      {:error, :not_found} ->
        Helpers.error_response(req, 404, "not_found", "Service '#{service_id}' not found")

      {:error, reason} ->
        Helpers.error_response(req, 500, "internal_error", inspect(reason))
    end
  end

  # ===== Private Helpers =====

  defp get_service_status(tenant_id, service_id) do
    Logger.info("[Gateway REST] Status request: #{tenant_id}/#{service_id}")

    case Solo.Deployment.Deployer.status(tenant_id, service_id) do
      status when is_map(status) ->
        Logger.info("[Gateway REST] Status found: #{tenant_id}/#{service_id}")

        # Fetch recent events for this service
        recent_events = fetch_recent_events(tenant_id, service_id, 10)

        response = %{
          service_id: service_id,
          status: if(status.alive, do: "running", else: "stopped"),
          alive: status.alive,
          created_at: Helpers.current_timestamp(),
          updated_at: Helpers.current_timestamp(),
          metadata: %{
            memory_bytes: extract_memory(status[:info]),
            message_queue_len: extract_message_queue_len(status[:info]),
            reductions: extract_reductions(status[:info])
          },
          recent_events: recent_events,
          timestamp: Helpers.current_timestamp()
        }

        {:ok, response}

      {:error, :not_found} ->
        Logger.warning("[Gateway REST] Service not found: #{tenant_id}/#{service_id}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[Gateway REST] Status failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp kill_service(tenant_id, service_id, req) do
    Logger.info("[Gateway REST] Kill request: #{tenant_id}/#{service_id}")

    # Get query parameters
    force = Helpers.qs_bool(req, "force", false)
    grace_ms = Helpers.qs_int(req, "grace_ms", 5000)

    opts = [timeout: grace_ms, force: force]

    case Solo.Deployment.Deployer.kill(tenant_id, service_id, opts) do
      :ok ->
        Logger.info("[Gateway REST] Kill success: #{tenant_id}/#{service_id}")

        response = %{
          service_id: service_id,
          status: "terminating",
          message: "Service termination initiated",
          grace_period_ms: grace_ms,
          timestamp: Helpers.current_timestamp()
        }

        {:ok, response}

      {:error, :not_found} ->
        Logger.warning(
          "[Gateway REST] Kill failed - service not found: #{tenant_id}/#{service_id}"
        )

        {:error, :not_found}

      {:error, reason} ->
        Logger.warning(
          "[Gateway REST] Kill failed: #{tenant_id}/#{service_id} - #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp fetch_recent_events(tenant_id, service_id, limit) do
    case Solo.EventStore.stream(tenant_id: tenant_id, service_id: service_id) do
      events when is_list(events) ->
        events
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.map(fn event ->
          %{
            id: event.id,
            event_type: to_string(event.event_type),
            timestamp: Helpers.format_timestamp(event.wall_clock),
            payload: event.payload
          }
        end)

      _ ->
        []
    end
  rescue
    _ ->
      # If event store fails, return empty list
      []
  end

  # ===== Process Info Extractors =====

  defp extract_memory(info) when is_map(info) do
    Map.get(info, :memory, 0)
  end

  defp extract_memory(_), do: 0

  defp extract_message_queue_len(info) when is_map(info) do
    Map.get(info, :message_queue_len, 0)
  end

  defp extract_message_queue_len(_), do: 0

  defp extract_reductions(info) when is_map(info) do
    Map.get(info, :reductions, 0)
  end

  defp extract_reductions(_), do: 0
end
