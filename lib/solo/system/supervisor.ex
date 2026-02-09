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
   5. Capability.Manager - capability token lifecycle (Phase 4)
   6. LoadShedder - gateway-level load shedding (Phase 5)
   7. Vault - encrypted secret storage (Phase 7)
   8. Telemetry - observability and metrics (Phase 7)
   9. Gateway - gRPC server with mTLS

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
       Solo.Deployment.Deployer,
       Solo.Capability.Manager,
       Solo.Backpressure.LoadShedder,
       {Solo.Vault, [db_path: "./data/vault"]},
       {Solo.Telemetry, [handlers: [:logger]]},
       Solo.Gateway
     ]

     Supervisor.init(children, strategy: :rest_for_one)
   end
end
