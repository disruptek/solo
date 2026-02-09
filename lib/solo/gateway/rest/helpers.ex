defmodule Solo.Gateway.REST.Helpers do
  @moduledoc """
  Shared helpers for REST API handlers.

  Provides utilities for:
  - Tenant extraction from headers/certificates
  - JSON encoding/decoding
  - Error response formatting
  - Common request/response patterns
  """

  require Logger

  alias Jason

  # ===== Tenant Extraction =====

  @doc """
  Extract tenant_id from request (header or mTLS certificate).

  Returns:
  - {:ok, tenant_id, req} on success
  - {:error, reason, req} on failure
  """
  def extract_tenant_id(req) do
    case :cowboy_req.header("x-tenant-id", req) do
      {tenant_id, _req} when is_binary(tenant_id) and byte_size(tenant_id) > 0 ->
        {:ok, tenant_id, req}

      _ ->
        # Fallback to mTLS certificate
        case extract_tenant_from_cert(req) do
          {:ok, tenant_id} -> {:ok, tenant_id, req}
          :error -> {:error, "Missing X-Tenant-ID header or mTLS certificate", req}
        end
    end
  end

  @doc """
  Extract tenant_id from client certificate Common Name.

  Returns:
  - {:ok, tenant_id}
  - :error
  """
  def extract_tenant_from_cert(req) do
    case :cowboy_req.cert(req) do
      undefined ->
        :error

      cert_binary ->
        case :public_key.pkix_decode_cert(cert_binary, :otp) do
          {:OTPCertificate, _, _, {:OTPTBSCertificate, _, _, _, {_, subject_name}, _, _, _, _, _},
           _, _, _} ->
            extract_cn_from_subject(subject_name)

          _ ->
            :error
        end
    end
  end

  defp extract_cn_from_subject({:rdnSequence, rdns}) do
    rdns
    |> Enum.find_map(fn rdn ->
      case rdn do
        [{{2, 5, 4, 3}, _, cn}] -> {:ok, to_string(cn)}
        _ -> nil
      end
    end)
    |> case do
      {:ok, cn} -> {:ok, cn}
      nil -> :error
    end
  end

  defp extract_cn_from_subject(_), do: :error

  # ===== Request Body Handling =====

  @doc """
  Read request body and return as binary.
  """
  def read_body(req, max_size \\ 1_000_000) do
    case :cowboy_req.read_body(req, length: max_size) do
      {:ok, body, req} ->
        {:ok, body, req}

      {:more, _, req} ->
        {:error, "Request body too large", req}
    end
  end

  @doc """
  Parse JSON from request body.
  """
  def parse_json_body(req) do
    with {:ok, body, req} <- read_body(req),
         {:ok, params} <- decode_json(body) do
      {:ok, params, req}
    else
      {:error, reason, req} ->
        {:error, reason, req}

      {:error, reason} ->
        {:error, reason, req}
    end
  end

  # ===== JSON Encoding/Decoding =====

  @doc """
  Decode JSON string into map.
  """
  def decode_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, data} ->
        {:ok, data}

      {:error, %Jason.DecodeError{position: pos}} ->
        {:error, "Invalid JSON at position #{pos}"}
    end
  end

  @doc """
  Encode map to JSON string.
  """
  def encode_json(data) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ===== Response Formatting =====

  @doc """
  Return a successful JSON response.

  Status defaults to 200 (OK).
  """
  def json_response(req, status \\ 200, data) do
    case encode_json(data) do
      {:ok, body} ->
        req
        |> :cowboy_req.set_resp_header("content-type", "application/json")
        |> :cowboy_req.reply(status, %{}, body)

      {:error, reason} ->
        error_response(req, 500, "internal_error", "Failed to encode response: #{reason}")
    end
  end

  @doc """
  Return an error JSON response.

  Status defaults to 400 (Bad Request).
  """
  def error_response(req, status \\ 400, error_code, message, details \\ nil) do
    data = %{
      error: error_code,
      message: message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    data = if details, do: Map.put(data, :details, details), else: data

    case encode_json(data) do
      {:ok, body} ->
        req
        |> :cowboy_req.set_resp_header("content-type", "application/json")
        |> :cowboy_req.reply(status, %{}, body)

      {:error, _reason} ->
        # Fallback to plain text if JSON encoding fails
        fallback_error(req, status, "#{error_code}: #{message}")
    end
  end

  defp fallback_error(req, status, message) do
    req
    |> :cowboy_req.set_resp_header("content-type", "text/plain")
    |> :cowboy_req.reply(status, %{}, message)
  end

  # ===== Query Parameter Helpers =====

  @doc """
  Get query parameter as string, with optional default.
  """
  def qs_val(req, key, default \\ nil) do
    case :cowboy_req.qs_val(key, req) do
      {value, _} when is_binary(value) -> value
      :undefined -> default
    end
  end

  @doc """
  Get query parameter as integer, with optional default.
  """
  def qs_int(req, key, default \\ 0) do
    case qs_val(req, key) do
      nil ->
        default

      val ->
        case Integer.parse(val) do
          {int, _} -> int
          :error -> default
        end
    end
  end

  @doc """
  Get query parameter as boolean, with optional default.
  """
  def qs_bool(req, key, default \\ false) do
    case qs_val(req, key) do
      nil -> default
      "true" -> true
      "false" -> false
      "1" -> true
      "0" -> false
      _ -> default
    end
  end

  # ===== Logging =====

  @doc """
  Log REST API request with tenant and action.
  """
  def log_request(method, path, tenant_id) do
    Logger.info("[REST] #{method} #{path} - tenant: #{tenant_id}")
  end

  @doc """
  Log REST API response with status and details.
  """
  def log_response(status, details) when is_binary(details) do
    Logger.info("[REST] Response: #{status} - #{details}")
  end

  def log_response(status, error_code, message) do
    Logger.warning("[REST] Response: #{status} - #{error_code}: #{message}")
  end

  # ===== Validation =====

  @doc """
  Validate service_id format.

  Must be non-empty string of alphanumeric chars, hyphens, underscores.
  """
  def validate_service_id(service_id) do
    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, service_id) and byte_size(service_id) > 0 do
      :ok
    else
      {:error, "Invalid service_id format"}
    end
  end

  @doc """
  Validate required fields in request body.
  """
  def validate_required_fields(params, required) do
    missing = Enum.filter(required, fn field -> !Map.has_key?(params, field) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  # ===== Pagination =====

  @doc """
  Apply pagination to a list.

  Returns {paginated_list, total_count}
  """
  def paginate(list, limit \\ 100, offset \\ 0) when is_list(list) do
    total = length(list)

    paginated =
      list
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {paginated, total}
  end

  @doc """
  Build pagination metadata for response.
  """
  def pagination_meta(items, total, limit, offset) do
    %{
      total: total,
      limit: limit,
      offset: offset,
      count: length(items)
    }
  end

  # ===== Timestamps =====

  @doc """
  Get current timestamp in ISO 8601 format.
  """
  def current_timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  @doc """
  Format datetime as ISO 8601.
  """
  def format_timestamp(datetime) do
    DateTime.to_iso8601(datetime)
  end
end
