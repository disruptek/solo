# SOLO Project Structure & Code Templates

## Directory Layout

```
solo/
├── README.md                          # Project overview
├── mix.exs                            # Dependencies & config
├── mix.lock                           # Locked versions
├── Dockerfile                         # Production image
├── docker-compose.yml                 # Local dev environment
│
├── lib/
│   └── solo/
│       ├── application.ex             # OTP Application module
│       ├── kernel.ex                  # Root supervisor
│       ├── supervisor_tree.ex         # Supervisor hierarchy
│       │
│       ├── core/
│       │   ├── capability.ex          # Unforgeable tokens
│       │   ├── capability_manager.ex  # Grant/revoke logic
│       │   ├── attenuated_service.ex  # Permission wrapper
│       │   ├── registry.ex            # Service discovery
│       │   └── process_limits.ex      # Resource constraints
│       │
│       ├── deployment/
│       │   ├── service_deployer.ex    # Code loading & spawn
│       │   ├── compiler.ex            # Elixir compilation
│       │   ├── code_loader.ex         # BEAM bytecode loading
│       │   └── external_binary.ex     # Port management
│       │
│       ├── api/
│       │   ├── grpc_handler.ex        # gRPC service impl
│       │   └── grpc_server.ex         # gRPC startup
│       │
│       ├── kernel/
│       │   ├── system_supervisor.ex   # System services tree
│       │   ├── driver_supervisor.ex   # Drivers tree
│       │   └── user_supervisor.ex     # User services tree
│       │
│       ├── drivers/
│       │   ├── filesystem.ex          # Filesystem driver
│       │   ├── network.ex             # Network driver
│       │   └── hardware.ex            # Hardware access
│       │
│       ├── services/
│       │   ├── audit_log.ex           # Event logging
│       │   ├── resource_monitor.ex    # Memory/CPU tracking
│       │   └── boot_loader.ex         # Initialization
│       │
│       ├── persistence/
│       │   ├── persistence.ex         # Strategy interface
│       │   ├── ets_backend.ex         # In-memory store
│       │   └── rocksdb_backend.ex     # Disk-backed store
│       │
│       ├── observability/
│       │   ├── metrics.ex             # Prometheus export
│       │   ├── tracing.ex             # Distributed tracing
│       │   └── backends/
│       │       ├── prometheus.ex      # Prometheus backend
│       │       ├── file.ex            # File logging backend
│       │       └── http.ex            # HTTP webhook backend
│       │
│       ├── deployment_strategies/
│       │   ├── rolling_update.ex      # Rolling update
│       │   ├── canary.ex              # Canary deployment
│       │   └── blue_green.ex          # Blue-green deploy
│       │
│       └── utils/
│           ├── config.ex              # Configuration
│           ├── logger.ex              # Structured logging
│           └── errors.ex              # Error definitions
│
├── proto/
│   └── solo/
│       └── v1/
│           └── solo.proto             # gRPC definitions
│
├── native/
│   └── solo_native/
│       ├── Cargo.toml                 # Rust NIF package
│       └── src/
│           ├── lib.rs                 # Rust NIF code
│           └── crypto.rs              # Crypto helpers (future)
│
├── test/
│   ├── support/
│   │   ├── case.ex                    # Test helpers
│   │   └── fixtures.ex                # Test data
│   ├── solo_test.exs                  # Application tests
│   ├── capability_test.exs            # Capability tests
│   ├── deployment_test.exs            # Deployment tests
│   ├── grpc_test.exs                  # API tests
│   ├── resource_limits_test.exs       # Resource tests
│   ├── persistence_test.exs           # Persistence tests
│   ├── chaos_test.exs                 # Chaos engineering
│   └── property_test.exs              # Property-based tests
│
├── examples/
│   ├── http_server.exs                # Example: HTTP service
│   ├── data_pipeline.exs              # Example: ETL pipeline
│   ├── worker_pool.exs                # Example: Parallel workers
│   ├── stateful_service.exs           # Example: Persistent state
│   └── README.md                      # Examples guide
│
├── config/
│   ├── config.exs                     # Shared config
│   ├── dev.exs                        # Development config
│   ├── test.exs                       # Test config
│   └── prod.exs                       # Production config
│
├── docs/
│   ├── README.md                      # Documentation index
│   ├── architecture.md                # Architecture deep-dive
│   ├── capability_model.md            # Capability system
│   ├── api.md                         # gRPC API reference
│   ├── deployment_guide.md            # How to deploy
│   ├── security.md                    # Security model
│   └── examples.md                    # Usage examples
│
└── scripts/
    ├── generate_proto.sh              # Compile .proto files
    ├── start_solo.sh                  # Boot script
    ├── docker_build.sh                # Docker build helper
    └── test_chaos.sh                  # Run chaos tests
```

---

## Key Module Templates

### 1. Root Supervisor (`lib/solo/kernel.ex`)

```elixir
defmodule Solo.Kernel do
  @moduledoc """
  Root supervisor for solo kernel.
  
  Manages the complete supervisor hierarchy:
  - System services (audit, registry, monitor)
  - Hardware drivers (filesystem, network)
  - User service supervisor
  """
  
  use Supervisor
  require Logger
  
  def start_link(opts) do
    Logger.info("Starting Solo Kernel...")
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    children = [
      # System supervisor (critical services)
      {Solo.Kernel.SystemSupervisor, []},
      
      # Driver supervisor (filesystem, network, etc.)
      {Solo.Kernel.DriverSupervisor, []},
      
      # User service supervisor (LLM-deployed services)
      {Solo.Kernel.UserSupervisor, []},
      
      # gRPC API server
      {Solo.API.GrpcServer, [port: 50051]},
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
  
  def deploy(service_spec) do
    Solo.ServiceDeployer.deploy(service_spec)
  end
  
  def kill(service_id, opts \\ []) do
    Solo.ServiceDeployer.kill(service_id, opts)
  end
end
```

### 2. Capability Module (`lib/solo/core/capability.ex`)

```elixir
defmodule Solo.Capability do
  @moduledoc """
  Unforgeable capability tokens.
  
  - Token creation with permissions
  - Token validation (expiry, revocation)
  - Permission checking (allowlist)
  """
  
  defstruct [
    :resource_pid,
    :token_hash,
    :permissions,
    :expires_at,
    :agent_id,
    :revoked?
  ]
  
  @type t :: %__MODULE__{
    resource_pid: pid(),
    token_hash: String.t(),
    permissions: [String.t()],
    expires_at: integer(),
    agent_id: String.t(),
    revoked?: boolean()
  }
  
  @doc """
  Create a new capability token.
  
  - resource_pid: PID of the resource
  - permissions: List of allowed operations
  - ttl_ms: Time-to-live in milliseconds
  - agent_id: ID of the agent creating this token
  """
  def create(resource_pid, permissions, ttl_ms, agent_id \\ "system") do
    %__MODULE__{
      resource_pid: resource_pid,
      token_hash: :crypto.strong_rand_bytes(32) |> Base.encode16(),
      permissions: permissions,
      expires_at: System.monotonic_time(:millisecond) + ttl_ms,
      agent_id: agent_id,
      revoked?: false
    }
  end
  
  @doc """
  Check if a capability is valid.
  
  - Not revoked
  - Not expired
  """
  def valid?(%__MODULE__{} = cap) do
    not cap.revoked? and 
      System.monotonic_time(:millisecond) <= cap.expires_at
  end
  
  @doc """
  Check if a capability allows a specific permission.
  """
  def allows?(%__MODULE__{} = cap, permission) do
    valid?(cap) and permission in cap.permissions
  end
  
  @doc """
  Revoke a capability immediately.
  """
  def revoke(%__MODULE__{} = cap) do
    %{cap | revoked?: true}
  end
  
  @doc """
  Check if a capability matches a given token hash.
  """
  def matches_token?(%__MODULE__{} = cap, token_hash) do
    cap.token_hash == token_hash
  end
end
```

### 3. Service Deployer (`lib/solo/deployment/service_deployer.ex`)

```elixir
defmodule Solo.ServiceDeployer do
  @moduledoc """
  Deploy and manage services.
  
  Supports:
  - Elixir source code (compile at runtime)
  - BEAM bytecode (load directly)
  - External binaries (spawn via Port)
  """
  
  use GenServer
  require Logger
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Deploy a service.
  
  spec: %{
    service_id: string,
    code: binary,
    format: :elixir_source | :beam_bytecode | :external_binary,
    capabilities: [capability_token],
    resource_limits: resource_limits_map,
    ...
  }
  """
  def deploy(spec) do
    GenServer.call(__MODULE__, {:deploy, spec}, 30_000)
  end
  
  @doc """
  Kill a running service.
  """
  def kill(service_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    GenServer.call(__MODULE__, {:kill, service_id, force})
  end
  
  @impl true
  def init(_opts) do
    {:ok, %{services: %{}}}
  end
  
  @impl true
  def handle_call({:deploy, spec}, _from, state) do
    case do_deploy(spec) do
      {:ok, service_pid} ->
        new_state = put_in(state.services[spec.service_id], service_pid)
        {:reply, {:ok, service_pid}, new_state}
      
      {:error, reason} = error ->
        Logger.error("Deploy failed for #{spec.service_id}: #{reason}")
        {:reply, error, state}
    end
  end
  
  def handle_call({:kill, service_id, force}, _from, state) do
    case Map.get(state.services, service_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      
      pid ->
        if force do
          Process.exit(pid, :kill)
        else
          Process.exit(pid, :shutdown)
        end
        new_state = Map.delete(state.services, service_id)
        {:reply, :ok, new_state}
    end
  end
  
  defp do_deploy(spec) do
    case spec.format do
      :elixir_source ->
        deploy_elixir_source(spec)
      
      :beam_bytecode ->
        deploy_beam_bytecode(spec)
      
      :external_binary ->
        deploy_external_binary(spec)
    end
  end
  
  defp deploy_elixir_source(spec) do
    # Compile Elixir source code
    case Solo.Compiler.compile(spec.code) do
      {:ok, module} ->
        # Spawn service process
        {:ok, _} = apply(module, :start_link, [spec.capabilities])
      
      {:error, reason} ->
        {:error, {:compile_error, reason}}
    end
  end
  
  defp deploy_beam_bytecode(spec) do
    # Load BEAM bytecode
    case Solo.CodeLoader.load(spec.code) do
      {:ok, module} ->
        # Spawn service process
        {:ok, _} = apply(module, :start_link, [spec.capabilities])
      
      {:error, reason} ->
        {:error, {:load_error, reason}}
    end
  end
  
  defp deploy_external_binary(spec) do
    # Execute external binary via Port
    Solo.ExternalBinary.spawn(spec)
  end
end
```

### 4. gRPC Handler (`lib/solo/api/grpc_handler.ex`)

```elixir
defmodule Solo.API.GrpcHandler do
  @moduledoc """
  gRPC service implementation for SoloKernel.
  
  Handles Deploy, Status, Kill, Watch, etc. RPC calls.
  """
  
  require Logger
  
  def deploy(request, _stream) do
    Logger.info("Deploy request: #{request.service_id}")
    
    spec = %{
      service_id: request.service_id,
      code: request.code,
      format: code_format_from_proto(request.format),
      capabilities: request.initial_capabilities,
      resource_limits: request.resource_limits,
      environment: request.environment,
    }
    
    case Solo.Kernel.deploy(spec) do
      {:ok, pid} ->
        %Proto.Solo.V1.DeployResponse{
          service_id: request.service_id,
          pid: inspect(pid),
          status: :RUNNING
        }
      
      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: reason
    end
  end
  
  def status(request, _stream) do
    case Solo.ServiceDeployer.status(request.service_id) do
      {:ok, info} ->
        %Proto.Solo.V1.StatusResponse{
          service_id: request.service_id,
          status: status_to_proto(info.status),
          pid: info.pid,
          current_usage: resource_usage_to_proto(info.usage),
          uptime_seconds: info.uptime,
          restart_count: info.restart_count,
        }
      
      {:error, :not_found} ->
        raise GRPC.RPCError, status: :not_found, message: "Service not found"
    end
  end
  
  def kill(request, _stream) do
    timeout_ms = request.timeout_ms || 30_000
    force = request.force || false
    
    case Solo.Kernel.kill(request.service_id, force: force, timeout: timeout_ms) do
      :ok ->
        %Proto.Solo.V1.KillResponse{
          service_id: request.service_id,
          final_status: :STOPPED
        }
      
      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: reason
    end
  end
  
  def watch(request, stream) do
    {:ok, stream_pid} = GenServer.start_link(
      Solo.API.WatchStream,
      {request.service_id, stream}
    )
    
    # Keep the stream alive
    Process.link(stream_pid)
    {:ok, stream}
  end
  
  # Helper functions
  
  defp code_format_from_proto(:ELIXIR_SOURCE), do: :elixir_source
  defp code_format_from_proto(:BEAM_BYTECODE), do: :beam_bytecode
  defp code_format_from_proto(:EXTERNAL_BINARY), do: :external_binary
  
  defp status_to_proto(:running), do: :RUNNING
  defp status_to_proto(:stopped), do: :STOPPED
  defp status_to_proto(:error), do: :ERROR
  
  defp resource_usage_to_proto(usage) do
    %Proto.Solo.V1.ResourceUsage{
      memory_bytes: usage.memory,
      message_queue_len: usage.queue_len,
      reductions: usage.reductions,
    }
  end
end
```

### 5. Attenuated Service Wrapper (`lib/solo/core/attenuated_service.ex`)

```elixir
defmodule Solo.AttenuatedService do
  @moduledoc """
  Wraps a service with permission checking.
  
  Only allows operations in the allowed_ops list.
  All other operations are rejected with :forbidden.
  """
  
  use GenServer
  require Logger
  
  def start_link({wrapped_pid, allowed_ops}) do
    GenServer.start_link(__MODULE__, {wrapped_pid, allowed_ops})
  end
  
  @impl true
  def init({wrapped_pid, allowed_ops}) do
    {:ok, %{wrapped_pid: wrapped_pid, allowed_ops: allowed_ops}}
  end
  
  @impl true
  def handle_call({:operation, op_name, args}, from, state) do
    if operation_allowed?(op_name, state.allowed_ops) do
      # Forward to wrapped service
      GenServer.call(state.wrapped_pid, {:operation, op_name, args})
    else
      Logger.warn("Forbidden operation: #{op_name}")
      {:reply, {:error, :forbidden}, state}
    end
  end
  
  defp operation_allowed?(op_name, allowed_ops) do
    op_name in allowed_ops
  end
end
```

### 6. Resource Limits (`lib/solo/core/process_limits.ex`)

```elixir
defmodule Solo.ProcessLimits do
  @moduledoc """
  Enforce resource limits on processes.
  
  - Max heap size (memory)
  - Max processes (children)
  - Message queue monitoring
  - CPU accounting via reductions
  """
  
  def spawn_with_limits(fun, limits) do
    Process.spawn(fun, build_spawn_options(limits))
  end
  
  def apply_limits(pid, limits) do
    Process.put_limits(pid, build_spawn_options(limits))
  end
  
  def monitor(pid, limits) do
    max_memory = limits.max_memory_bytes || :infinity
    max_queue = limits.message_queue_limit || :infinity
    
    Task.start(fn ->
      monitor_loop(pid, max_memory, max_queue)
    end)
  end
  
  defp build_spawn_options(limits) do
    [
      {:max_heap_size, limits.max_memory_bytes || 1_000_000_000},
      {:message_queue_data, :off_heap},
      {:priority, process_priority(limits.cpu_shares)}
    ]
  end
  
  defp process_priority(cpu_shares) when cpu_shares >= 2048, do: :high
  defp process_priority(cpu_shares) when cpu_shares >= 1024, do: :normal
  defp process_priority(_), do: :low
  
  defp monitor_loop(pid, max_memory, max_queue) do
    case Process.info(pid, [:memory, :message_queue_len]) do
      [{:memory, mem}, {:message_queue_len, queue}] ->
        if mem > max_memory do
          Logger.warn("Process #{inspect(pid)} exceeded memory limit: #{mem}")
          # Could trigger action here (kill, alert, etc.)
        end
        
        if queue > max_queue do
          Logger.warn("Process #{inspect(pid)} queue buildup: #{queue}")
        end
        
        Process.sleep(1000)
        monitor_loop(pid, max_memory, max_queue)
      
      _ ->
        # Process died, exit monitor
        :ok
    end
  end
end
```

---

## mix.exs Dependencies

```elixir
defp deps do
  [
    # Core
    {:grpc, "~> 0.6.0"},
    {:protobuf, "~> 0.11.0"},
    {:google_protos, "~> 0.3"},
    
    # Observability
    {:prometheus_ex, "~> 3.0"},
    {:prometheus_plugs, "~> 1.1"},
    {:logger_json, "~> 5.1"},
    
    # Performance & Native
    {:rustler, "~> 0.33"},
    {:rocksdb, "~> 1.8"},
    
    # Testing
    {:stream_data, "~> 0.6", only: :test},  # Property testing
    {:mox, "~> 1.0", only: :test},           # Mocking
    
    # Utilities
    {:credo, "~> 1.7", only: [:dev, :test]},
    {:dialyxir, "~> 1.4", only: [:dev, :test]},
    {:ex_doc, "~> 0.30", only: :dev},
  ]
end
```

---

## mix.exs Configuration

```elixir
def project do
  [
    app: :solo,
    version: "0.1.0-dev",
    elixir: "~> 1.14",
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    releases: releases(),
    
    # Code quality
    dialyzer: [
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
    ],
    
    # Documentation
    docs: [
      main: "Solo",
      extras: ["README.md"],
    ],
  ]
end

def application do
  [
    mod: {Solo.Application, []},
    extra_applications: [:logger]
  ]
end

def releases do
  [
    solo: [
      version: "0.1.0",
      applications: [runtime_tools: :permanent],
      include_executables_for: [:unix],
      steps: [:assemble, :tar],
    ]
  ]
end
```

---

## Test Structure Example

```elixir
# test/capability_test.exs
defmodule Solo.CapabilityTest do
  use ExUnit.Case
  
  describe "create/3" do
    test "creates a valid capability token" do
      cap = Solo.Capability.create(self(), ["read"], 3600_000, "agent1")
      
      assert cap.resource_pid == self()
      assert cap.permissions == ["read"]
      assert Solo.Capability.valid?(cap)
    end
  end
  
  describe "allows?/2" do
    test "allows granted permissions" do
      cap = Solo.Capability.create(self(), ["read", "write"], 3600_000)
      
      assert Solo.Capability.allows?(cap, "read")
      assert Solo.Capability.allows?(cap, "write")
      refute Solo.Capability.allows?(cap, "delete")
    end
  end
end

# test/property_test.exs - Property-based isolation tests
defmodule Solo.PropertyTest do
  use ExUnit.Case
  use ExUnitProperties
  
  property "capabilities cannot be forged" do
    check all cap1 <- capability_generator(),
              cap2 <- capability_generator() do
      
      # Two independently created capabilities should never be equal
      assert cap1.token_hash != cap2.token_hash
    end
  end
  
  property "attenuated service never allows disallowed operations" do
    check all ops <- list_of(string(:alphanumeric), min_length: 1) do
      {:ok, wrapped_pid} = TestService.start_link()
      {:ok, attenuated_pid} = Solo.AttenuatedService.start_link({wrapped_pid, ops})
      
      # Test that disallowed operations are rejected
      Enum.each(ops, fn op ->
        assert {:ok, _} = GenServer.call(attenuated_pid, {:operation, op, []})
      end)
      
      assert {:error, :forbidden} = 
        GenServer.call(attenuated_pid, {:operation, "disallowed", []})
    end
  end
end
```

---

This structure provides a solid foundation for Phase 1 implementation. Each module has a clear responsibility and the templates show the expected interface patterns.

**Next:** Ready to start Phase 1 when you give the go-ahead!
