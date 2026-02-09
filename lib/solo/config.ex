defmodule Solo.Config do
  @moduledoc """
  Configuration management for Solo.

  Supports:
  - Default configuration from application env
  - TOML-based configuration files
  - Runtime configuration updates
  - Per-tenant configuration overrides

  Configuration schema:

  ```toml
  [solo]
  listen_port = 50051
  http_port = 8080
  data_dir = "./data"
  max_tenants = 100
  log_level = "info"

  [limits]
  max_per_tenant = 100
  max_total = 1000

  [telemetry]
  enabled = true
  log_events = true

  [security]
  require_mtls = false
  rate_limit_per_capability = 1000

  [database]
  events_db = "./data/events"
  vault_db = "./data/vault"
  ```
  """

  require Logger

  @default_config %{
    solo: %{
      listen_port: 50051,
      http_port: 8080,
      data_dir: "./data",
      max_tenants: 100,
      log_level: "info"
    },
    limits: %{
      max_per_tenant: 100,
      max_total: 1000
    },
    telemetry: %{
      enabled: true,
      log_events: true
    },
    security: %{
      require_mtls: false,
      rate_limit_per_capability: 1000
    },
    database: %{
      events_db: "./data/events",
      vault_db: "./data/vault"
    }
  }

  @doc """
  Load configuration from file.

  Supports TOML and JSON formats.
  Returns merged configuration (file config overrides defaults).
  """
  def load(file_path) when is_binary(file_path) do
    Logger.info("[Config] Loading configuration from #{file_path}")

    case File.read(file_path) do
      {:ok, content} ->
        case parse_config(file_path, content) do
          {:ok, file_config} ->
            Logger.info("[Config] Configuration loaded successfully")
            {:ok, merge_config(@default_config, file_config)}

          {:error, reason} ->
            Logger.warning("[Config] Failed to parse configuration: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[Config] Failed to read configuration file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get default configuration.
  """
  def default do
    @default_config
  end

  @doc """
  Get a configuration value by path.

  Example: `Solo.Config.get(config, [:solo, :listen_port])`
  """
  def get(config, path) when is_map(config) and is_list(path) do
    get_in(config, path)
  end

  @doc """
  Get a configuration value with a default fallback.
  """
  def get(config, path, default) when is_map(config) and is_list(path) do
    get_in(config, path) || default
  end

  @doc """
  Set a configuration value.
  """
  def set(config, path, value) when is_map(config) and is_list(path) do
    put_in(config, path, value)
  end

  @doc """
  Validate configuration structure.
  """
  def validate(config) when is_map(config) do
    # Check required sections
    case {Map.get(config, :solo), Map.get(config, :database)} do
      {nil, _} ->
        {:error, "Missing required 'solo' section"}

      {_, nil} ->
        {:error, "Missing required 'database' section"}

      {solo, db} ->
        # Validate port values
        case {Map.get(solo, :listen_port), Map.get(solo, :http_port)} do
          {port1, port2}
          when is_integer(port1) and is_integer(port2) and port1 > 0 and port2 > 0 ->
            # Validate database paths
            case {Map.get(db, :events_db), Map.get(db, :vault_db)} do
              {events_path, vault_path} when is_binary(events_path) and is_binary(vault_path) ->
                :ok

              _ ->
                {:error, "Invalid database paths in configuration"}
            end

          _ ->
            {:error, "Invalid port configuration"}
        end
    end
  end

  @doc """
  Get configuration for a specific tenant.

  Returns merged configuration (global + tenant-specific overrides).
  """
  def for_tenant(config, tenant_id) when is_binary(tenant_id) do
    tenant_config = get(config, [:tenants, tenant_id], %{})
    merge_config(config, tenant_config)
  end

  # === Private Helpers ===

  defp parse_config(file_path, content) do
    cond do
      String.ends_with?(file_path, ".toml") ->
        parse_toml(content)

      String.ends_with?(file_path, ".json") ->
        parse_json(content)

      true ->
        {:error, "Unsupported configuration format"}
    end
  end

  defp parse_toml(content) do
    case Toml.decode(content) do
      {:ok, config} -> {:ok, atomize_keys(config)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, config} -> {:ok, atomize_keys(config)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {String.to_atom(key), atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value

  defp merge_config(base, overrides) when is_map(base) and is_map(overrides) do
    Map.merge(base, overrides, fn _key, base_value, override_value ->
      if is_map(base_value) and is_map(override_value) do
        merge_config(base_value, override_value)
      else
        override_value
      end
    end)
  end

  defp merge_config(base, _overrides), do: base
end
