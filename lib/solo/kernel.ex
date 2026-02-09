defmodule Solo.Kernel do
  @moduledoc """
  Root supervisor for the entire Solo system.

  Uses :one_for_one strategy: if a child crashes, only that child is restarted.

  Children:
  1. Solo.System.Supervisor - core system services
  2. Solo.Tenant.Supervisor - dynamic supervisor for tenant hierarchies
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    Logger.info("[Kernel] Starting Solo kernel")

    children = [
      Solo.System.Supervisor,
      {Solo.Tenant.Supervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
