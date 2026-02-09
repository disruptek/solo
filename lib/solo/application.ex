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
    config_path = System.get_env("SOLO_CONFIG")

    case config_path do
      nil ->
        Logger.debug("SOLO_CONFIG not set, using default configuration")

      path when is_binary(path) ->
        case File.exists?(path) do
          true ->
            Logger.info("Loading configuration from #{path}")

            case Solo.Config.load(path) do
              {:ok, config} ->
                # Store configuration in application environment
                Application.put_env(:solo, :config, config)
                Logger.info("Configuration loaded successfully")

              {:error, reason} ->
                Logger.warning("Failed to load configuration: #{inspect(reason)}, using defaults")
                # Continue with defaults
            end

          false ->
            Logger.warning("Configuration file not found: #{path}, using defaults")
        end
    end
  end
end
