defmodule Solo.System.Supervisor do
  @moduledoc """
  Supervisor for system-level services.

  Uses :rest_for_one strategy: if a child crashes, all children started after it
  are restarted, but children before it are left alone.

  Children (in order):
  1. EventStore - the append-only log
  2. AtomMonitor - runtime atom table monitoring
  3. Registry - service discovery
  4. Deployer - service deployment and lifecycle management

  The order matters because later children depend on earlier ones.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Solo.EventStore, [db_path: "./data/events"]},
      Solo.AtomMonitor,
      {Solo.Registry, []},
      Solo.Deployment.Deployer
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
