defmodule SoloCLI do
  @moduledoc """
  Solo CLI - Command-line interface for Solo kernel management.

  Usage:
    solo deploy <service.ex> [--tenant=TENANT_ID] [--service-id=SERVICE_ID]
    solo status [--tenant=TENANT_ID] [--service-id=SERVICE_ID]
    solo kill <service_id> [--tenant=TENANT_ID] [--force]
    solo list [--tenant=TENANT_ID]
    solo secrets [get|set|delete] <key> [<value>] [--tenant=TENANT_ID]
    solo logs [--tenant=TENANT_ID] [--service-id=SERVICE_ID] [--tail=N]
    solo metrics [--json]
    solo health [--json]
    solo version
    solo help [COMMAND]

  Examples:
    solo deploy myservice.ex --tenant=acme --service-id=api
    solo status --tenant=acme
    solo kill api --tenant=acme --force
    solo list --tenant=acme
    solo secrets set DB_URL postgres://localhost/mydb --tenant=acme
    solo metrics --json
    solo health
  """

  require Logger

  @version "0.2.0"
  @gateway_host Application.compile_env(:solo, :gateway_host, "localhost")
  @gateway_port Application.compile_env(:solo, :gateway_port, 50051)
  @http_host Application.compile_env(:solo, :http_host, "localhost")
  @http_port Application.compile_env(:solo, :http_port, 8080)

  def main(args) do
    case args do
      [] ->
        print_help()
        System.halt(0)

      ["help" | rest] ->
        print_help(rest)
        System.halt(0)

      ["version"] ->
        IO.puts("Solo #{@version}")
        System.halt(0)

      [command | args] ->
        run_command(command, args)
    end
  end

  # === Commands ===

  defp run_command("deploy", args) do
    case parse_args(args, [:file]) do
      {:ok, options} ->
        file = options[:file]
        tenant_id = options[:tenant] || default_tenant()
        service_id = options[:"service-id"] || Path.basename(file, ".ex")

        case File.read(file) do
          {:ok, code} ->
            deploy_service(tenant_id, service_id, code, options)

          {:error, reason} ->
            IO.puts(:stderr, "Error: Could not read file #{file}: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("status", args) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        service_id = options[:"service-id"]

        if service_id do
          get_service_status(tenant_id, service_id, options)
        else
          list_services(tenant_id, options)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("kill", [service_id | args]) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        force = Keyword.has_key?(options, :force)

        kill_service(tenant_id, service_id, force, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("kill", []) do
    IO.puts(:stderr, "Error: service_id required")
    System.halt(1)
  end

  defp run_command("list", args) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        list_services(tenant_id, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("secrets", ["get", key | args]) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        get_secret(tenant_id, key, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("secrets", ["set", key, value | args]) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        set_secret(tenant_id, key, value, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("secrets", ["delete", key | args]) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        delete_secret(tenant_id, key, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("secrets", _args) do
    IO.puts(:stderr, "Error: secrets command requires [get|set|delete] subcommand")
    System.halt(1)
  end

  defp run_command("logs", args) do
    case parse_args(args, []) do
      {:ok, options} ->
        tenant_id = options[:tenant] || default_tenant()
        service_id = options[:"service-id"]
        tail = String.to_integer(options[:tail] || "50")

        get_logs(tenant_id, service_id, tail, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("metrics", args) do
    case parse_args(args, []) do
      {:ok, options} ->
        json = Keyword.has_key?(options, :json)
        get_metrics(json, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command("health", args) do
    case parse_args(args, []) do
      {:ok, options} ->
        json = Keyword.has_key?(options, :json)
        get_health(json, options)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_command(command, _args) do
    IO.puts(:stderr, "Error: Unknown command '#{command}'")
    print_help()
    System.halt(1)
  end

  # === HTTP API Calls ===

  defp deploy_service(tenant_id, service_id, code, _options) do
    url = "http://#{@http_host}:#{@http_port}/services"

    body =
      Jason.encode!(%{
        "service_id" => service_id,
        "code" => code,
        "format" => "elixir_source"
      })

    case :httpc.request(
           :post,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}],
            'application/json', body},
           [],
           []
         ) do
      {:ok, {{_version, 201, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts("✓ Service deployed: #{service_id}")
        IO.puts("  Status: #{response["status"]}")

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Deployment failed (#{status})")
        IO.puts(:stderr, "  Error: #{response["error"]}")
        IO.puts(:stderr, "  Message: #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_service_status(tenant_id, service_id, _options) do
    url = "http://#{@http_host}:#{@http_port}/services/#{service_id}"

    case :httpc.request(
           :get,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}]},
           [],
           []
         ) do
      {:ok, {{_version, 200, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)

        IO.puts("Service: #{response["service_id"]}")
        IO.puts("  Status: #{if response["alive"], do: "running", else: "stopped"}")
        IO.puts("  Memory: #{format_bytes(response["memory_bytes"])}")
        IO.puts("  Messages: #{response["message_queue_len"]}")
        IO.puts("  Reductions: #{response["reductions"]}")

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Error (#{status}): #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp kill_service(tenant_id, service_id, force, _options) do
    url = "http://#{@http_host}:#{@http_port}/services/#{service_id}"

    case :httpc.request(
           :delete,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}]},
           [],
           []
         ) do
      {:ok, {{_version, 202, _}, _headers, _response_body}} ->
        IO.puts("✓ Service #{service_id} scheduled for termination")
        if force, do: IO.puts("  Force kill enabled")

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Error (#{status}): #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp list_services(tenant_id, _options) do
    url = "http://#{@http_host}:#{@http_port}/services"

    case :httpc.request(
           :get,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}]},
           [],
           []
         ) do
      {:ok, {{_version, 200, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        services = response["services"] || []

        if Enum.empty?(services) do
          IO.puts("No services found for tenant #{tenant_id}")
        else
          IO.puts("Services for tenant #{tenant_id}:")

          Enum.each(services, fn service ->
            status = if service["alive"], do: "✓", else: "✗"
            IO.puts("  #{status} #{service["service_id"]}")
          end)
        end

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Error (#{status}): #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_health(json, _options) do
    url = "http://#{@http_host}:#{@http_port}/health"

    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_version, 200, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)

        if json do
          IO.puts(Jason.encode!(response, pretty: true))
        else
          IO.puts("Solo Health Status")
          IO.puts("  Status: #{response["status"]}")
          IO.puts("  Version: #{response["version"]}")
          IO.puts("  Uptime: #{format_ms(response["uptime_ms"])}")
          IO.puts("  Memory: #{response["memory_mb"]}MB")
          IO.puts("  Processes: #{response["process_count"]}")
        end

      {:ok, {{_version, status, _}, _headers, _response_body}} ->
        IO.puts(:stderr, "✗ Server error (#{status})")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_metrics(json, _options) do
    url = "http://#{@http_host}:#{@http_port}/metrics"

    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_version, 200, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)

        if json do
          IO.puts(Jason.encode!(response, pretty: true))
        else
          IO.puts("Solo Metrics")
          IO.puts("  Timestamp: #{response["timestamp"]}")
          IO.puts("  Uptime: #{format_ms(response["uptime_ms"])}")
          IO.puts("  Memory: #{response["memory_mb"]}MB")
          IO.puts("  Processes: #{response["process_count"]}")
        end

      {:ok, {{_version, status, _}, _headers, _response_body}} ->
        IO.puts(:stderr, "✗ Server error (#{status})")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_secret(tenant_id, key, _options) do
    url = "http://#{@http_host}:#{@http_port}/secrets/#{key}"

    case :httpc.request(
           :get,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}]},
           [],
           []
         ) do
      {:ok, {{_version, 200, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)

        IO.puts("✓ Secret: #{key}")
        IO.puts("  Exists: #{response["exists"]}")

      {:ok, {{_version, 404, _}, _headers, _response_body}} ->
        IO.puts(:stderr, "✗ Secret not found: #{key}")
        System.halt(1)

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Error (#{status}): #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp set_secret(tenant_id, key, value, _options) do
    url = "http://#{@http_host}:#{@http_port}/secrets"

    body =
      Jason.encode!(%{
        "key" => key,
        "value" => value
      })

    case :httpc.request(
           :post,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}],
            'application/json', body},
           [],
           []
         ) do
      {:ok, {{_version, 201, _}, _headers, _response_body}} ->
        IO.puts("✓ Secret set: #{key}")

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Error (#{status}): #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp delete_secret(tenant_id, key, _options) do
    url = "http://#{@http_host}:#{@http_port}/secrets/#{key}"

    case :httpc.request(
           :delete,
           {String.to_charlist(url), [{'X-Tenant-Id', String.to_charlist(tenant_id)}]},
           [],
           []
         ) do
      {:ok, {{_version, 204, _}, _headers, _response_body}} ->
        IO.puts("✓ Secret deleted: #{key}")

      {:ok, {{_version, 404, _}, _headers, _response_body}} ->
        IO.puts(:stderr, "✗ Secret not found: #{key}")
        System.halt(1)

      {:ok, {{_version, status, _}, _headers, response_body}} ->
        response = Jason.decode!(response_body)
        IO.puts(:stderr, "✗ Error (#{status}): #{response["message"]}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_logs(tenant_id, service_id, tail, _options) do
    # Build query parameters
    query_params = []

    query_params =
      if service_id, do: query_params ++ [{"service_id", service_id}], else: query_params

    query_params = query_params ++ [{"limit", Integer.to_string(tail)}]

    # Build URL with query string
    base_url = "http://#{@http_host}:#{@http_port}/logs"
    query_string = URI.encode_query(query_params)
    url = if query_string != "", do: "#{base_url}?#{query_string}", else: base_url

    # Request with streaming
    case :httpc.request(
           :get,
           {String.to_charlist(url),
            [{'X-Tenant-Id', String.to_charlist(tenant_id)}, {'Accept', 'text/event-stream'}]},
           [],
           stream: :self
         ) do
      {:ok, _request_id} ->
        # Stream events from the server
        stream_logs()

      {:error, reason} ->
        IO.puts(:stderr, "✗ Connection error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp stream_logs do
    receive do
      {:http, {_request_id, :stream_start, _headers}} ->
        stream_logs()

      {:http, {_request_id, :stream, data}} ->
        # Parse Server-Sent Events format
        data
        |> String.split("\n", trim: true)
        |> Enum.each(&process_log_event/1)

        stream_logs()

      {:http, {_request_id, :stream_end, _headers}} ->
        :ok

      {:http, {_request_id, {{_version, status, _}, _headers, _body}}} ->
        if status != 200 do
          IO.puts(:stderr, "✗ Error (#{status})")
          System.halt(1)
        end
    after
      30000 -> :ok
    end
  end

  defp process_log_event("data: " <> json_str) do
    case Jason.decode(json_str) do
      {:ok, log} ->
        timestamp = log["timestamp"] || ""
        level = log["level"] || "INFO"
        message = log["message"] || ""
        service_id = log["service_id"] || "unknown"

        IO.puts("[#{timestamp}] #{level} (#{service_id}): #{message}")

      {:error, _} ->
        :ok
    end
  end

  defp process_log_event(_), do: :ok

  # === Helpers ===

  defp parse_args(args, positional) do
    {opts, positionals} = OptionParser.parse!(args, strict: [tenant: :string, force: :boolean])

    case positionals do
      [] when positional == [] ->
        {:ok, opts}

      [] when positional != [] ->
        {:error, "Missing positional argument"}

      values ->
        positional_map =
          Enum.reduce(positional, %{}, fn key, acc -> Map.put(acc, key, hd(values)) end)

        {:ok, Keyword.to_list(opts) ++ Map.to_list(positional_map)}
    end
  rescue
    _e -> {:error, "Invalid arguments"}
  end

  defp default_tenant do
    System.get_env("SOLO_TENANT", "default_tenant")
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes < 1024 -> "#{bytes}B"
      bytes < 1024 * 1024 -> "#{div(bytes, 1024)}KB"
      bytes < 1024 * 1024 * 1024 -> "#{div(bytes, 1024 * 1024)}MB"
      true -> "#{div(bytes, 1024 * 1024 * 1024)}GB"
    end
  end

  defp format_bytes(_), do: "0B"

  defp format_ms(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp format_ms(_), do: "0s"

  defp print_help(args \\ []) do
    case args do
      ["deploy"] ->
        IO.puts("""
        solo deploy - Deploy a new service

        Usage:
          solo deploy <service.ex> [--tenant=TENANT_ID] [--service-id=SERVICE_ID]

        Options:
          --tenant=TENANT_ID        Tenant ID (default: SOLO_TENANT env var or 'default_tenant')
          --service-id=SERVICE_ID   Service ID (default: basename of file)

        Example:
          solo deploy myservice.ex --tenant=acme --service-id=api
        """)

      ["status"] ->
        IO.puts("""
        solo status - Get service status

        Usage:
          solo status [--tenant=TENANT_ID] [--service-id=SERVICE_ID]

        Options:
          --tenant=TENANT_ID        Tenant ID
          --service-id=SERVICE_ID   Service ID (shows single service, omit to list all)

        Example:
          solo status --tenant=acme --service-id=api
        """)

      _ ->
        IO.puts(@moduledoc)
    end
  end
end
