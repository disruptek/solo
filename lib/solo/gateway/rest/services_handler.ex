defmodule Solo.Gateway.REST.ServicesHandler do
  @moduledoc """
  Cowboy HTTP handler for /services endpoint.

  Supports:
  - POST /services - Deploy a new service
  - GET /services - List all services for a tenant
  """

  require Logger

  alias Solo.Gateway.REST.Helpers

  def init(req, state) do
    {:cowboy_rest, req, state}
  end

  # ===== HTTP Methods =====

  def allowed_methods(req, state) do
    {["GET", "POST", "OPTIONS"], req, state}
  end

  def options(req, state) do
    {:ok, req, state}
  end

  # ===== Content Negotiation =====

  def content_types_provided(req, state) do
    {[{"application/json", :to_json}], req, state}
  end

  def content_types_accepted(req, state) do
    {[{"application/json", :from_json}], req, state}
  end

  # ===== POST /services - Deploy Service =====

  def from_json(req, state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req),
         {:ok, params, req} <- Helpers.parse_json_body(req),
         :ok <- Helpers.validate_required_fields(params, ["service_id", "code"]),
         :ok <- Helpers.validate_service_id(params["service_id"]),
         {:ok, _pid} <- deploy_service(tenant_id, params) do
      Helpers.log_request("POST", "/services", tenant_id)

      response = %{
        service_id: params["service_id"],
        status: "deployed",
        message: "Service deployed successfully",
        timestamp: Helpers.current_timestamp()
      }

      Helpers.json_response(req, 201, response)
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, reason, req} ->
        handle_deploy_error(req, reason)

      {:error, reason} ->
        handle_deploy_error(req, reason)
    end
  end

  # ===== GET /services - List Services =====

  def to_json(req, state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req),
         services <- list_services_for_tenant(tenant_id) do
      Helpers.log_request("GET", "/services", tenant_id)

      # Apply pagination
      limit = Helpers.qs_int(req, "limit", 100) |> min(1000)
      offset = Helpers.qs_int(req, "offset", 0)
      {paginated, total} = Helpers.paginate(services, limit, offset)

      # Filter by status if requested
      status_filter = Helpers.qs_val(req, "status")
      filtered = if status_filter, do: filter_by_status(paginated, status_filter), else: paginated

      response = %{
        services: filtered,
        total: total,
        limit: limit,
        offset: offset,
        timestamp: Helpers.current_timestamp()
      }

      case Helpers.encode_json(response) do
        {:ok, body} ->
          req
          |> :cowboy_req.set_resp_header("content-type", "application/json")
          |> :cowboy_req.reply(200, %{}, body)

        {:error, reason} ->
          Helpers.error_response(
            req,
            500,
            "internal_error",
            "Failed to encode response: #{reason}"
          )
      end
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, reason, req} ->
        Helpers.error_response(req, 500, "internal_error", reason)
    end
  end

  # ===== Private Helpers =====

  defp deploy_service(tenant_id, params) do
    Logger.info("[Gateway REST] Deploy request: #{tenant_id}/#{params["service_id"]}")

    case Solo.Deployment.Deployer.deploy(%{
           tenant_id: tenant_id,
           service_id: params["service_id"],
           code: params["code"],
           format: :elixir_source
         }) do
      {:ok, pid} ->
        Logger.info("[Gateway REST] Deploy success: #{tenant_id}/#{params["service_id"]}")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "[Gateway REST] Deploy failed: #{tenant_id}/#{params["service_id"]} - #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp list_services_for_tenant(tenant_id) do
    Logger.info("[Gateway REST] List request for tenant: #{tenant_id}")

    services = Solo.Deployment.Deployer.list(tenant_id)

    Enum.map(services, fn {service_id, _pid} ->
      case Solo.Deployment.Deployer.status(tenant_id, service_id) do
        status when is_map(status) ->
          %{
            service_id: service_id,
            status: if(status.alive, do: "running", else: "stopped"),
            alive: status.alive,
            created_at: Helpers.current_timestamp(),
            metadata: %{
              memory_bytes: extract_memory(status[:info]),
              message_queue_len: extract_message_queue_len(status[:info]),
              reductions: extract_reductions(status[:info])
            }
          }

        {:error, _} ->
          %{
            service_id: service_id,
            status: "unknown",
            alive: false,
            created_at: Helpers.current_timestamp(),
            metadata: %{}
          }
      end
    end)
  end

  defp filter_by_status(services, status_filter) do
    Enum.filter(services, fn service ->
      String.downcase(service.status) == String.downcase(status_filter)
    end)
  end

  defp handle_deploy_error(req, reason) do
    case reason do
      "Missing required fields: " <> _ ->
        Helpers.error_response(req, 400, "invalid_request", reason)

      "Invalid service_id format" ->
        Helpers.error_response(req, 400, "invalid_service_id", reason)

      "Invalid JSON" <> _ ->
        Helpers.error_response(req, 400, "invalid_json", reason)

      _ ->
        Helpers.error_response(
          req,
          500,
          "internal_error",
          "Service deployment failed: #{inspect(reason)}"
        )
    end
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
