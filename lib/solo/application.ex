defmodule Solo.Application do
  @moduledoc false

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    Logger.info("Solo application starting...")

    # Load configuration from file if it exists
    load_configuration()

    children = [
      Solo.Kernel
    ]

    opts = [strategy: :one_for_one, name: Solo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Application
  def stop(_state) do
    Logger.info("Solo application stopping...")
    :ok
  end

  # === Private Helpers ===

  defp load_configuration do
    config_path = System.get_env("SOLO_CONFIG", "config.toml")

    case File.exists?(config_path) do
      true ->
        Logger.info("Loading configuration from #{config_path}")

        case Solo.Config.load(config_path) do
          {:ok, config} ->
            # Store configuration in application environment
            Application.put_env(:solo, :config, config)
            Logger.info("Configuration loaded successfully")

          {:error, reason} ->
            Logger.warning("Failed to load configuration: #{inspect(reason)}")
            # Continue with defaults
        end

      false ->
        Logger.debug("Configuration file not found (#{config_path}), using defaults")
    end
  end
end
