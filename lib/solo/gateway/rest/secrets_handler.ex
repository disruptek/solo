defmodule Solo.Gateway.REST.SecretsHandler do
  @moduledoc """
  Cowboy HTTP handler for /secrets endpoint.

  Supports:
  - POST /secrets - Set a secret for a tenant
  - GET /secrets/{key} - Retrieve a secret value
  - DELETE /secrets/{key} - Delete a secret
  - GET /secrets - List secret keys for a tenant
  """

  require Logger

  alias Solo.Gateway.REST.Helpers

  def init(req, state) do
    {:cowboy_rest, req, state}
  end

  # ===== HTTP Methods =====

  def allowed_methods(req, state) do
    {["GET", "POST", "DELETE", "OPTIONS"], req, state}
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

  # ===== POST /secrets - Set Secret =====

  def from_json(req, _state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req),
         {:ok, params, req} <- Helpers.parse_json_body(req),
         :ok <- Helpers.validate_required_fields(params, ["key", "value"]),
         :ok <- validate_secret_key(params["key"]),
         :ok <- set_secret(tenant_id, params["key"], params["value"]) do
      Helpers.log_request("POST", "/secrets", tenant_id)

      response = %{
        key: params["key"],
        status: "stored",
        message: "Secret stored successfully",
        timestamp: Helpers.current_timestamp()
      }

      Helpers.json_response(req, 201, response)
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, reason, req} ->
        handle_secret_error(req, reason)

      {:error, reason} ->
        handle_secret_error(req, reason)
    end
  end

  # ===== GET /secrets or /secrets/{key} =====

  def to_json(req, _state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req) do
      path = :cowboy_req.path(req)

      case path do
        "/secrets" ->
          # List all secret keys
          handle_list_secrets(req, tenant_id)

        _ ->
          # Extract key from path /secrets/{key}
          case String.split(path, "/", trim: true) do
            ["secrets", key] ->
              handle_get_secret(req, tenant_id, key)

            _ ->
              Helpers.error_response(req, 400, "invalid_path", "Invalid path format")
          end
      end
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required")

      {:error, reason, req} ->
        Helpers.error_response(req, 500, "internal_error", reason)
    end
  end

  # ===== DELETE /secrets/{key} =====

  def delete_resource(req, state) do
    with {:ok, tenant_id, req} <- Helpers.extract_tenant_id(req) do
      path = :cowboy_req.path(req)

      case String.split(path, "/", trim: true) do
        ["secrets", key] ->
          case delete_secret(tenant_id, key) do
            :ok ->
              Helpers.log_request("DELETE", "/secrets/#{key}", tenant_id)

              response = %{
                key: key,
                status: "deleted",
                message: "Secret deleted successfully",
                timestamp: Helpers.current_timestamp()
              }

              {true, Helpers.json_response(req, 200, response), state}

            {:error, reason} ->
              handle_secret_error(req, reason)
              {false, req, state}
          end

        _ ->
          {false, Helpers.error_response(req, 400, "invalid_path", "Invalid path format"), state}
      end
    else
      {:error, "Missing X-Tenant-ID header or mTLS certificate", req} ->
        {false,
         Helpers.error_response(req, 400, "missing_tenant_id", "X-Tenant-ID header required"),
         state}

      {:error, reason, req} ->
        {false, Helpers.error_response(req, 500, "internal_error", reason), state}
    end
  end

  # ===== Private Helpers =====

  defp handle_list_secrets(req, tenant_id) do
    case Solo.Vault.list_secrets(tenant_id) do
      {:ok, secrets} ->
        Helpers.log_request("GET", "/secrets", tenant_id)

        # Apply pagination
        limit = Helpers.qs_int(req, "limit", 100) |> min(1000)
        offset = Helpers.qs_int(req, "offset", 0)
        {paginated, total} = Helpers.paginate(secrets, limit, offset)

        response = %{
          secrets: paginated,
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

      {:error, reason} ->
        Helpers.error_response(
          req,
          500,
          "internal_error",
          "Failed to list secrets: #{inspect(reason)}"
        )
    end
  end

  defp handle_get_secret(req, tenant_id, key) do
    # For security, we don't retrieve the actual value through the API
    # Instead, we just check if the secret exists
    case Solo.Vault.list_secrets(tenant_id) do
      {:ok, secrets} ->
        if Enum.member?(secrets, key) do
          Helpers.log_request("GET", "/secrets/#{key}", tenant_id)

          response = %{
            key: key,
            exists: true,
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
          Helpers.error_response(req, 404, "not_found", "Secret key not found: #{key}")
        end

      {:error, reason} ->
        Helpers.error_response(
          req,
          500,
          "internal_error",
          "Failed to retrieve secret: #{inspect(reason)}"
        )
    end
  end

  defp set_secret(tenant_id, key, value) do
    # Use tenant_id as the encryption key
    case Solo.Vault.store(tenant_id, key, value, tenant_id) do
      :ok ->
        Logger.info("[Gateway REST] Secret stored: #{tenant_id}/#{key}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Gateway REST] Secret storage failed: #{tenant_id}/#{key} - #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp delete_secret(tenant_id, key) do
    case Solo.Vault.revoke(tenant_id, key) do
      :ok ->
        Logger.info("[Gateway REST] Secret revoked: #{tenant_id}/#{key}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Gateway REST] Secret revocation failed: #{tenant_id}/#{key} - #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp validate_secret_key(key)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 256 do
    case String.match?(key, ~r/^[a-zA-Z0-9_-]+$/) do
      true -> :ok
      false -> {:error, "Invalid secret key format (must be alphanumeric, dash, or underscore)"}
    end
  end

  defp validate_secret_key(_) do
    {:error, "Invalid secret key (must be between 1 and 256 characters)"}
  end

  defp handle_secret_error(req, reason) do
    case reason do
      "Missing required fields: " <> _ ->
        Helpers.error_response(req, 400, "invalid_request", reason)

      "Invalid secret key" <> _ ->
        Helpers.error_response(req, 400, "invalid_secret_key", reason)

      "Invalid JSON" <> _ ->
        Helpers.error_response(req, 400, "invalid_json", reason)

      _ ->
        Helpers.error_response(
          req,
          500,
          "internal_error",
          "Secret operation failed: #{inspect(reason)}"
        )
    end
  end
end
