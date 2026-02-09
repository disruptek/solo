defmodule Solo.Application do
  @moduledoc false

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    Logger.info("Solo application starting...")

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
end
