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

  defp get_secret(_tenant_id, _key, _options) do
    IO.puts("✓ Secrets support coming in v0.3.0")
  end

  defp set_secret(_tenant_id, _key, _value, _options) do
    IO.puts("✓ Secrets support coming in v0.3.0")
  end

  defp delete_secret(_tenant_id, _key, _options) do
    IO.puts("✓ Secrets support coming in v0.3.0")
  end

  defp get_logs(_tenant_id, _service_id, _tail, _options) do
    IO.puts("✓ Logs support coming in v0.3.0")
  end

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
