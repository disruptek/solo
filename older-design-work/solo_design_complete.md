# SOLO: User-Level Operating System - Complete Design Document

**Version:** 1.0  
**Status:** Ready for Implementation  
**Last Updated:** 2026-02-08

---

## Executive Summary

**Solo** is a bulletproof user-level operating system written in Elixir, designed to run on a single powerful Linux host. It enables LLM agents to deploy services on demand with strong isolation guarantees, capability-based access control, and 99.99% reliability. Solo leverages Erlang/OTP's battle-tested actor model to provide a secure, distributed platform for service execution.

**Core Promise:** Services deployed through solo have mathematical guarantees of isolation and access control, with automatic recovery from failures.

---

## 1. System Architecture

### 1.1 Architectural Layers

```
┌────────────────────────────────────────────────────────────┐
│ Layer 7: User Services                                     │
│ (LLM-deployed microservices, pipelines, workers)           │
├────────────────────────────────────────────────────────────┤
│ Layer 6: Service API & Control Plane                       │
│ (gRPC for deploy/manage/observe/versions)                  │
├────────────────────────────────────────────────────────────┤
│ Layer 5: Service-to-Service Communication                  │
│ (Direct PID send, registry lookup, Erlang distribution)    │
├────────────────────────────────────────────────────────────┤
│ Layer 4: Isolation & Capability Model                      │
│ (Unforgeable tokens, attenuation, permission checking)     │
├────────────────────────────────────────────────────────────┤
│ Layer 3: Process Management & Resource Limits              │
│ (DynamicSupervisor, max_children, memory/CPU caps)         │
├────────────────────────────────────────────────────────────┤
│ Layer 2: Kernel Services                                   │
│ (Filesystem, network, hardware drivers, audit log)         │
├────────────────────────────────────────────────────────────┤
│ Layer 1: Erlang/OTP Runtime                                │
│ (Preemptive scheduler, GC, distribution protocol)          │
├────────────────────────────────────────────────────────────┤
│ Layer 0: Linux + Hardware                                  │
│ (Processes, memory, network, storage)                      │
└────────────────────────────────────────────────────────────┘
```

### 1.2 Process Supervision Hierarchy

```
solo_kernel (root supervisor, :one_for_one)
│
├─→ System Supervisor (:rest_for_one, critical)
│   ├─→ Audit Log Manager
│   ├─→ Capability Manager
│   ├─→ Process Registry
│   ├─→ Resource Monitor
│   ├─→ Configuration Manager
│   └─→ Boot Loader
│
├─→ Driver Supervisor (dynamic, :one_for_one)
│   ├─→ Filesystem Driver
│   ├─→ Network Driver
│   └─→ Hardware Driver(s)
│
├─→ System Service Supervisor (dynamic, :rest_for_one)
│   ├─→ System Service 1
│   └─→ System Service 2
│
└─→ User Process Supervisor (dynamic, :one_for_one)
    ├─→ User Service 1 (with internal supervisor tree)
    ├─→ User Service 2 (with internal supervisor tree)
    └─→ ...
```

**Supervision Strategy Rationale:**

- **Root (`:one_for_one`):** Isolated failure domains. One crashed user service doesn't cascade.
- **System (`:rest_for_one`):** Ordered startup: Audit Log → Capability Manager → Registry. Dependent services restart in order.
- **Drivers (`:one_for_one`):** Each driver independent. Driver crash restarts only that driver (with backoff to prevent restart storms).
- **System Services (`:rest_for_one`):** Services may depend on others; restart order preserved.
- **User Processes (`:one_for_one`):** Complete isolation between user deployments.

---

## 2. Service Tiers & Guarantees

### 2.1 Two-Tier Service Model

#### **Tier 1: System Services**
- Critical to kernel operation (filesystem, audit, resource monitor)
- Get priority in scheduling (higher CPU shares)
- Larger resource budgets
- Must complete operations within strict timeouts
- Cannot be killed by user services

**SLA:**
- 99.99% uptime (4 minutes/month downtime)
- P99 latency < 50ms
- Auto-restart on failure

#### **Tier 2: User Services**
- LLM-deployed, user-facing services
- Best-effort resource allocation
- Can be killed/restarted at any time
- Subject to resource limits
- May access only granted capabilities

**SLA:**
- Best-effort availability
- P99 latency depends on workload
- Restart on failure per configuration

### 2.2 Resource Limits (User Services)

All user service deployments have configurable limits:

```elixir
%Solo.ResourceLimits{
  max_processes: 100,              # Max child processes per service
  max_memory_bytes: 4_000_000_000, # 4GB per process
  cpu_shares: 1024,                # Relative CPU allocation
  message_queue_limit: 10_000,     # Alert if queue exceeds
  startup_timeout_ms: 100,         # Service must start in 100ms
  shutdown_timeout_ms: 30_000,     # 30s graceful shutdown before SIGKILL
  limit_exceeded_action: :configurable  # :kill | :throttle | :warn
}
```

---

## 3. Capability-Based Security Model

### 3.1 Defense in Depth (Three Layers)

#### **Layer 1: Unforgeable Process References (Erlang VM)**

Elixir PIDs are cryptographically unforgeable—only the Erlang kernel issues them. No fake PIDs can be created.

```elixir
# PIDs are unforgeable capabilities
{:ok, fs_driver_pid} = Filesystem.Driver.start_link()

# Pass only the PID to user service; user service can:
# 1. Send messages to this PID
# 2. Monitor this PID
# 3. Nothing else—cannot access other services

# If we want fine-grained control, wrap it:
{:ok, limited_fs} = Solo.AttenuatedProcess.start_link(
  fs_driver_pid,
  allowed_ops: ["read", "stat"]  # No writes allowed
)
```

#### **Layer 2: Capability Tokens (Message-Level)**

Tokens wrap resource PIDs with proof-of-authority, expiry, and permissions.

```elixir
defmodule Solo.Capability do
  defstruct [
    :resource_pid,      # PID of the resource
    :token_hash,        # Unforgeable token identifier
    :permissions,       # [:read, :write, :execute]
    :expires_at,        # Absolute time (System.monotonic_time)
    :agent_id,          # Which agent created this capability
    :revoked?           # Revocation flag
  ]
  
  def create(resource_pid, permissions, ttl_ms) do
    %Solo.Capability{
      resource_pid: resource_pid,
      token_hash: :crypto.strong_rand_bytes(32) |> Base.encode16(),
      permissions: permissions,
      expires_at: System.monotonic_time(:millisecond) + ttl_ms,
      revoked?: false
    }
  end
  
  def valid?(%Solo.Capability{} = cap) do
    not cap.revoked? and 
      System.monotonic_time(:millisecond) <= cap.expires_at
  end
  
  def revoke(%Solo.Capability{} = cap) do
    %{cap | revoked?: true}
  end
end
```

**Prevents confused deputy attacks:** A service cannot be tricked into using a capability it doesn't possess.

#### **Layer 3: OS-Level Isolation (Future - not MVP)**

When deployed via Docker (for clustering), seccomp/pledge/unveil restricts syscalls.

```dockerfile
# future: solo Dockerfile
FROM erlang:latest
RUN apt-get install -y libseccomp-dev
COPY solo /opt/solo
CMD ["seccomp-load", "/opt/solo/seccomp.json", "--", "/opt/solo/bin/solo"]
```

### 3.2 Capability Delegation & Attenuation

**Attenuated Process Wrapper:**

```elixir
defmodule Solo.AttenuatedService do
  use GenServer
  
  def start_link({wrapped_pid, allowed_ops}) do
    GenServer.start_link(__MODULE__, {wrapped_pid, allowed_ops})
  end
  
  def init({wrapped_pid, allowed_ops}) do
    {:ok, {wrapped_pid, allowed_ops}}
  end
  
  def handle_call({:operation, op_name, args}, from, {wrapped_pid, allowed}) do
    if Enum.member?(allowed, op_name) do
      # Forward to real service
      GenServer.call(wrapped_pid, {:operation, op_name, args})
    else
      {:reply, {:error, :forbidden}, {wrapped_pid, allowed}}
    end
  end
end
```

**Usage Example:**

```elixir
# Kernel grants filesystem access
{:ok, fs_pid} = Filesystem.Driver.start_link()

# Create limited read-only view
{:ok, limited_fs} = Solo.AttenuatedService.start_link({fs_pid, ["read", "stat"]})

# Pass to untrusted user service
Solo.ServiceDeployer.deploy(%{
  code: user_code,
  capabilities: [
    {:filesystem, limited_fs, ["read", "stat"]}
  ]
})

# User service can call:
GenServer.call(limited_fs, {:read, "/data/input.txt"})     # ✅ OK
GenServer.call(limited_fs, {:write, "/data/output.txt", data})  # ❌ FORBIDDEN
```

---

## 4. Service Deployment Model

### 4.1 Three Code Deployment Modes

#### **Mode 1: Inline Elixir Source Code**

Agent sends Elixir source as string; solo compiles at runtime.

```elixir
# Agent sends:
code = """
defmodule MyService do
  use GenServer
  
  def start_link(filesystem_capability) do
    GenServer.start_link(__MODULE__, filesystem_capability, name: :my_service)
  end
  
  def init(fs_cap) do
    {:ok, %{fs: fs_cap, data: []}}
  end
  
  def handle_call({:process}, _from, state) do
    # Process data
    {:reply, :ok, state}
  end
end
"""

# Agent calls:
{:ok, service_pid} = Solo.Kernel.deploy(%{
  service_id: "my_service_v1",
  code: code,
  format: :elixir_source,
  capabilities: [filesystem_cap],
  resource_limits: %{max_memory_bytes: 1_000_000_000}
})
```

**Pros:** Easy for agents to generate code dynamically  
**Cons:** Compilation overhead (~50-200ms per service)

#### **Mode 2: Pre-compiled BEAM Bytecode**

Agent sends `.beam` file (or multiple files as tarball); solo loads bytecode.

```elixir
# Agent pre-compiles service locally, sends binary
beam_binary = File.read!("my_service.beam")

{:ok, service_pid} = Solo.Kernel.deploy(%{
  service_id: "my_service_v1",
  code: beam_binary,
  format: :beam_bytecode,
  capabilities: [filesystem_cap],
  resource_limits: %{}
})
```

**Pros:** No compilation overhead; ~5-10ms startup  
**Cons:** Agent must have Elixir compiler available

#### **Mode 3: External Binary**

Agent provides path or tarball of executable (Go, Rust, Python, etc.); solo executes via `Port.open/2`.

```elixir
{:ok, service_pid} = Solo.Kernel.deploy(%{
  service_id: "ml_inference",
  code: "/opt/binaries/inference_server",
  format: :external_binary,
  capabilities: [filesystem_cap, network_cap],
  environment: %{"MODEL_PATH" => "/models/bert"}
})
```

**Pros:** Leverage other languages for specific needs  
**Cons:** Isolation boundary less fine-grained; requires IPC

### 4.2 Sub-100ms Startup Latency Strategy

**Optimization Path:**

1. **Pre-compilation:** Agents compile locally; send .beam files (5-10ms load time)
2. **Eager supervisor allocation:** Keep supervisor processes pre-warmed
3. **Zero-copy process spawning:** Erlang's process creation is ~100µs
4. **Bytecode caching:** Cache compiled modules to avoid recompile
5. **Parallel startup:** Supervisor spawns children in parallel

**Expected Timeline:**

```
Agent → gRPC call (1ms)
  ↓
Solo validates (2ms)
  ↓
Load bytecode (3ms)
  ↓
Spawn process (1ms)
  ↓
GenServer.start_link (2ms)
  ↓
Application.start callback (5-50ms depending on service)
────────────────────
Total: 14-60ms (goal: <100ms)
```

---

## 5. gRPC API Specification

### 5.1 Proto Definitions (Strict Schemas)

```protobuf
// solo/proto/solo.proto

syntax = "proto3";

package solo.v1;

service SoloKernel {
  // Deploy a new service
  rpc Deploy(DeployRequest) returns (DeployResponse);
  
  // Get service status
  rpc Status(StatusRequest) returns (StatusResponse);
  
  // Kill a running service
  rpc Kill(KillRequest) returns (KillResponse);
  
  // Stream service logs
  rpc Watch(WatchRequest) returns (stream WatchResponse);
  
  // Grant capability token
  rpc GrantCapability(CapabilityRequest) returns (CapabilityResponse);
  
  // List running services
  rpc List(ListRequest) returns (ListResponse);
  
  // Update service (rolling/canary)
  rpc Update(UpdateRequest) returns (UpdateResponse);
  
  // Shutdown gracefully
  rpc Shutdown(ShutdownRequest) returns (ShutdownResponse);
}

message DeployRequest {
  string service_id = 1;
  bytes code = 2;
  CodeFormat format = 3;
  
  repeated CapabilityGrant initial_capabilities = 4;
  ResourceLimits resource_limits = 5;
  map<string, string> environment = 6;
  ServiceTier tier = 7;
  DeploymentStrategy deployment_strategy = 8;
  
  // Persistence
  bool enable_persistence = 9;
  PersistenceConfig persistence_config = 10;
  
  // Logging
  LogLevel log_level = 11;
  bool audit_enabled = 12;
}

enum CodeFormat {
  ELIXIR_SOURCE = 0;
  BEAM_BYTECODE = 1;
  EXTERNAL_BINARY = 2;
}

message CapabilityGrant {
  string service_name = 1;  // "filesystem", "network", etc
  repeated string permissions = 2;
  int64 ttl_seconds = 3;
}

message ResourceLimits {
  int64 max_memory_bytes = 1;
  int32 max_processes = 2;
  int32 cpu_shares = 3;
  int32 message_queue_limit = 4;
  int32 startup_timeout_ms = 5;
  int32 shutdown_timeout_ms = 6;
  ResourceLimitAction limit_exceeded_action = 7;
}

enum ResourceLimitAction {
  KILL = 0;
  THROTTLE = 1;
  WARN = 2;
}

enum ServiceTier {
  USER = 0;
  SYSTEM = 1;
}

message DeploymentStrategy {
  oneof strategy {
    RollingUpdate rolling_update = 1;
    CanaryDeployment canary = 2;
    BlueGreen blue_green = 3;
  }
}

message RollingUpdate {
  int32 max_surge = 1;      // % of instances to create
  int32 max_unavailable = 2; // % of instances that can be unavailable
}

message CanaryDeployment {
  int32 initial_percentage = 1;  // Start with % traffic
  int32 increment_percentage = 2; // Increase by % per step
  int32 step_duration_seconds = 3;
}

message BlueGreen {
  int32 traffic_shift_delay_seconds = 1;
}

message PersistenceConfig {
  PersistenceBackend backend = 1;
  repeated string watch_keys = 2;  // Keys to auto-persist
}

enum PersistenceBackend {
  ETS = 0;           // Memory only
  ROCKSDB = 1;       // Disk-backed
  EXTERNAL = 2;      // Service manages own persistence
}

enum LogLevel {
  ERROR = 0;
  WARN = 1;
  INFO = 2;
  DEBUG = 3;
}

message DeployResponse {
  string service_id = 1;
  string pid = 2;  // Erlang PID as string: "<0.123.0>"
  Status status = 3;
}

enum Status {
  DEPLOYING = 0;
  RUNNING = 1;
  STOPPING = 2;
  STOPPED = 3;
  ERROR = 4;
}

message StatusRequest {
  string service_id = 1;
}

message StatusResponse {
  string service_id = 1;
  Status status = 2;
  string pid = 3;
  
  ResourceUsage current_usage = 4;
  int64 uptime_seconds = 5;
  int32 restart_count = 6;
  repeated string errors = 7;
}

message ResourceUsage {
  int64 memory_bytes = 1;
  int32 message_queue_len = 2;
  int64 reductions = 3;  // CPU work units
}

message KillRequest {
  string service_id = 1;
  bool force = 2;  // SIGKILL if true, SIGTERM if false
  int32 timeout_ms = 3;
}

message KillResponse {
  string service_id = 1;
  Status final_status = 2;
}

message WatchRequest {
  string service_id = 1;
  bool include_logs = 2;
  bool include_metrics = 3;
}

message WatchResponse {
  oneof event {
    LogEntry log = 1;
    MetricsSnapshot metrics = 2;
    StatusChange status_change = 3;
  }
}

message LogEntry {
  int64 timestamp_ms = 1;
  string level = 2;  // ERROR, WARN, INFO, DEBUG
  string message = 3;
}

message MetricsSnapshot {
  int64 timestamp_ms = 1;
  ResourceUsage usage = 2;
}

message StatusChange {
  Status new_status = 1;
  string reason = 2;
}

message CapabilityRequest {
  string service_id = 1;
  string resource_name = 2;
  repeated string permissions = 3;
  int64 ttl_seconds = 4;
}

message CapabilityResponse {
  bytes capability_token = 1;
  int64 expires_at_ms = 2;
}

message ListRequest {
  ServiceTier filter_tier = 1;  // Optional filter
}

message ListResponse {
  repeated ServiceInfo services = 1;
}

message ServiceInfo {
  string service_id = 1;
  string pid = 2;
  Status status = 3;
  ServiceTier tier = 4;
  int64 uptime_seconds = 5;
  ResourceUsage current_usage = 6;
}

message UpdateRequest {
  string service_id = 1;
  bytes new_code = 2;
  CodeFormat format = 3;
  DeploymentStrategy strategy = 4;
}

message UpdateResponse {
  string service_id = 1;
  Status new_status = 2;
}

message ShutdownRequest {
  int32 timeout_seconds = 1;
}

message ShutdownResponse {
  int32 actual_shutdown_time_seconds = 1;
}
```

### 5.2 API Call Examples

**Deploy an Elixir service:**

```bash
grpcurl -plaintext \
  -d '{
    "service_id": "word-counter",
    "code": "...",
    "format": "ELIXIR_SOURCE",
    "initial_capabilities": [
      {
        "service_name": "filesystem",
        "permissions": ["read"],
        "ttl_seconds": 3600
      }
    ],
    "resource_limits": {
      "max_memory_bytes": "1000000000",
      "max_processes": 50,
      "startup_timeout_ms": 100,
      "limit_exceeded_action": "KILL"
    },
    "tier": "USER",
    "log_level": "INFO"
  }' \
  localhost:50051 \
  solo.v1.SoloKernel/Deploy
```

**Watch service (streaming logs):**

```bash
grpcurl -plaintext \
  -d '{"service_id": "word-counter", "include_logs": true}' \
  localhost:50051 \
  solo.v1.SoloKernel/Watch
```

---

## 6. Inter-Service Communication

### 6.1 Three Communication Patterns

#### **Pattern 1: Direct Send (Lowest Latency)**

```elixir
# Service A sends message directly to Service B's PID
send(service_b_pid, {:request, data})

# Service B receives via handle_info
def handle_info({:request, data}, state) do
  {:noreply, process(data, state)}
end
```

**Latency:** ~1-5 µs  
**Use Case:** Fire-and-forget events

#### **Pattern 2: GenServer.call (Synchronous Request-Reply)**

```elixir
# Service A requests result from Service B
{:ok, result} = GenServer.call(service_b_pid, {:compute, input}, timeout: 5000)

# Service B replies
def handle_call({:compute, input}, _from, state) do
  {:reply, compute(input), state}
end
```

**Latency:** ~5-20 µs  
**Use Case:** Request-reply where caller waits

#### **Pattern 3: Registry Lookup (Service Discovery)**

```elixir
# Service A looks up Service B by name
case Registry.lookup(Solo.Registry, {:service, "service_b"}) do
  [{pid, metadata}] ->
    GenServer.call(pid, {:compute, input})
  [] ->
    {:error, :not_found}
end

# Service B registers on startup
Registry.register(Solo.Registry, {:service, "service_b"}, %{capabilities: [:compute]})
```

**Latency:** ~10-50 µs  
**Use Case:** Dynamic discovery, pub/sub

### 6.2 Multi-Machine Communication (Future)

When solo instances are distributed, services reference processes on other machines via Erlang distribution:

```elixir
# Solo instances form a cluster
:net_kernel.connect(:"solo_instance_2@host2")

# Service on instance 1 calls service on instance 2 transparently
GenServer.call({:service_b, :"solo_instance_2@host2"}, {:compute, input})
```

**Protocol:** Erlang Distribution Protocol (TCP with message framing)  
**Latency:** ~100-500 µs (adds network latency)  
**TLS Support:** Encrypt inter-node communication

---

## 7. Persistence Model

### 7.1 Three Persistence Modes

#### **Mode 1: Stateless (No Persistence)**

Service has no persistent state; each restart is clean.

```elixir
deploy(%{
  service_id: "worker",
  enable_persistence: false,
  ...
})
```

#### **Mode 2: Memory + Disk (Hybrid)**

Hot data in ETS (fast), periodically flushed to RocksDB (durable).

```elixir
deploy(%{
  service_id: "cache",
  enable_persistence: true,
  persistence_config: %{
    backend: :rocksdb,
    watch_keys: ["cache:*"]  # Auto-persist keys matching pattern
  }
})

# In service:
:ets.insert(:cache_table, {"key", value})
# Automatically synced to RocksDB every 5 seconds

# On restart:
# RocksDB data is restored to ETS before service starts
```

#### **Mode 3: Manual Persistence (Service Manages Own)**

Service uses external database (Redis, Postgres, etc).

```elixir
deploy(%{
  service_id: "user_service",
  enable_persistence: true,
  persistence_config: %{
    backend: :external,
    external_connection: "postgresql://..."
  }
})

# In service:
defmodule UserService do
  def handle_call({:get, key}, _from, state) do
    {:ok, value} = Postgres.query(state.db, "SELECT value FROM kv WHERE key = ?", [key])
    {:reply, value, state}
  end
end
```

---

## 8. Observability & Audit

### 8.1 Pluggable Observability Backend

Solo supports multiple metrics/tracing backends:

```elixir
# In solo config
config :solo,
  observability: %{
    metrics_backend: :prometheus,    # or :otel, :custom_http
    tracing_backend: :jaeger,        # Distributed tracing
    custom_handler: MyCustomHandler   # Pluggable module
  }
```

**Metrics Available:**

- `solo_deployment_count` (counter)
- `solo_active_services` (gauge)
- `solo_service_memory_bytes` (histogram, per service)
- `solo_service_startup_ms` (histogram)
- `solo_grpc_request_duration_ms` (histogram)
- `solo_capability_grants_total` (counter)

### 8.2 Mandatory Audit Log

All significant events are logged to audit trail (pluggable backend):

```elixir
defmodule Solo.AuditLog do
  def log(event) do
    entry = %{
      timestamp: System.monotonic_time(:millisecond),
      event_type: event.type,  # :deploy, :kill, :grant_capability, :shutdown
      service_id: event.service_id,
      agent_id: event.agent_id,
      details: event.details,
      result: event.result  # :success or :error with reason
    }
    
    # Send to pluggable backends
    for backend <- configured_backends() do
      backend.log(entry)
    end
  end
end

# Backends: local file, syslog, external HTTP endpoint, etc.
```

**Audit Events Logged:**

- Service deployment (code, capabilities, resources)
- Service termination (reason, exit code)
- Capability grants/revocations
- Resource limit violations
- Kernel updates
- Graceful shutdown

---

## 9. Service Versioning & Deployment Strategies

### 9.1 Rolling Updates

```
Version 1: [Instance 1, Instance 2, Instance 3]
                ↓
Redeploy 1:     [Instance 1', Instance 2, Instance 3]
                ↓
Redeploy 2:     [Instance 1', Instance 2', Instance 3]
                ↓
Redeploy 3:     [Instance 1', Instance 2', Instance 3']
```

**Configuration:**

```elixir
deploy(%{
  service_id: "api_server",
  code: new_code,
  deployment_strategy: %{
    rolling_update: %{
      max_surge: 1,           # Create 1 new instance ahead
      max_unavailable: 0      # Keep all running
    }
  }
})
```

### 9.2 Canary Deployment

```
Version 1: [V1, V1, V1, V1, V1, V1, V1, V1, V1, V1] (100% v1)
                ↓
Canary 1:  [V2, V1, V1, V1, V1, V1, V1, V1, V1, V1] (10% v2)
           ↓ Wait 5 min, check metrics
Canary 2:  [V2, V2, V2, V1, V1, V1, V1, V1, V1, V1] (30% v2)
           ↓ Wait 5 min
Canary 3:  [V2, V2, V2, V2, V2, V2, V2, V2, V2, V2] (100% v2)
```

**Configuration:**

```elixir
deploy(%{
  deployment_strategy: %{
    canary: %{
      initial_percentage: 10,
      increment_percentage: 20,
      step_duration_seconds: 300
    }
  }
})
```

### 9.3 Blue-Green Deployment

```
Blue (current):  [Instance 1, Instance 2, Instance 3] ← Active
Green (new):     [Instance 4, Instance 5, Instance 6] ← Warming up
                                    ↓ (1min tests pass)
Green (current):  [Instance 4, Instance 5, Instance 6] ← Active
Blue (old):       [Instance 1, Instance 2, Instance 3] ← Draining/killed
```

---

## 10. Kernel Hot-Reload

Solo supports updating kernel code without full restart:

### 10.1 Strategy

1. **System services** (non-critical) update with `:rest_for_one` restart
2. **Critical services** (filesystem) update via code_change callback
3. **Driver updates** happen independently per driver
4. **Zero-downtime migrations** via `GenServer.code_change/3`

```elixir
defmodule Filesystem.Driver do
  use GenServer
  
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end
  
  # Called during hot code reload
  def code_change(old_version, state, _extra) do
    Logger.info("Filesystem driver updating from #{old_version}")
    
    # Migrate state if needed
    new_state = case old_version do
      1 -> Map.put(state, :cache, %{})  # Add cache field
      2 -> state  # No changes
      _ -> state
    end
    
    {:ok, new_state}
  end
end
```

### 10.2 Safe Update Procedure

```
1. Compile new kernel code locally
2. Load into sandbox process
3. Run tests on sandbox
4. Swap code via :code.load_file/1
5. Trigger code_change callbacks on affected servers
6. Monitor for errors
7. Rollback if issues detected
```

---

## 11. Docker-Based Deployment

### 11.1 Dockerfile

```dockerfile
FROM erlang:27-alpine

RUN apk add --no-cache \
    git \
    build-base \
    gcc

WORKDIR /opt/solo

# Copy project files
COPY . .

# Build release
RUN mix do \
      local.hex --force, \
      local.rebar --force, \
      deps.get, \
      release

# Runtime
FROM erlang:27-alpine
RUN apk add --no-cache bash
COPY --from=0 /opt/solo/_build/prod/rel/solo /opt/solo

# Healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD /opt/solo/bin/solo rpc ping

EXPOSE 50051

CMD ["/opt/solo/bin/solo", "start"]
```

### 11.2 Compose for Local Development

```yaml
version: '3.9'

services:
  solo:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: solo_kernel
    ports:
      - "50051:50051"    # gRPC
      - "9090:9090"      # Prometheus metrics
    environment:
      NODE_NAME: solo@localhost
      ERLANG_COOKIE: solo_dev
      LOG_LEVEL: info
    volumes:
      - ./data:/opt/solo/data
    healthcheck:
      test: ["CMD", "/opt/solo/bin/solo", "rpc", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    restart: unless-stopped
```

---

## 12. Bootstrap & Initialization

### 12.1 Boot Sequence

```
1. Erlang VM starts
2. Solo application starts
3. Supervisor tree initialized:
   a. System Supervisor spawns (Audit Log → Registry → Monitor)
   b. Driver Supervisor spawns
   c. User Supervisor spawns (empty)
4. gRPC server binds to port 50051
5. Boot complete, ready for deployments
```

### 12.2 Boot Script

```bash
#!/bin/bash
# start_solo.sh

export NODE_NAME="solo@$(hostname)"
export ERLANG_COOKIE="prod_secret_key"
export RELEASE_DISTRIBUTION="name"  # Use :name mode
export ERL_ZFLAGS="-kernel net_setuptime 15000"

exec /opt/solo/bin/solo start
```

### 12.3 Graceful Shutdown

```
1. Receive SIGTERM
2. Mark as "shutting down"
3. Stop accepting new deployments
4. Wait for existing services to finish (30s timeout)
5. Send SIGTERM to each service
6. Wait for graceful shutdown
7. Kill remaining processes (SIGKILL)
8. Shutdown system supervisor
9. Exit with code 0
```

---

## 13. Threat Model & Security Posture

### 13.1 Threats Addressed

| Threat | Layer | Mitigation | Strength |
|--------|-------|-----------|----------|
| Service A accesses Service B's memory | 1 | Erlang process isolation | ⭐⭐⭐⭐⭐ |
| Confused deputy (tricked op) | 2 | Capability tokens + permission checks | ⭐⭐⭐⭐⭐ |
| Privilege escalation to kernel | 2 | Attenuation wrapper, no service gets raw PIDs | ⭐⭐⭐⭐ |
| Resource exhaustion (CPU, memory) | 3 | Resource limits, CPU shares, memory caps | ⭐⭐⭐⭐ |
| Unauthorized syscalls | 3 | Seccomp (future, in Docker) | ⭐⭐⭐ |
| Denial of service (crash kernel) | 1 | Supervisor trees, isolation, recovery | ⭐⭐⭐⭐⭐ |
| Malicious code execution | 3 | Code signing (future), sandboxing (future) | ⭐⭐ (MVP) |

### 13.2 Assumptions & Limitations

**MVP does NOT provide:**
- Code signing/verification
- Fine-grained syscall filtering (seccomp)
- Hardware security features (TPM, SGX)
- Formal proof of isolation guarantees

**MVP DOES provide:**
- Actor model isolation (Erlang)
- Capability-based tokens
- Resource limits
- Audit logging
- Graceful failure handling

---

## 14. Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Service startup latency | <100ms | Pre-compiled BEAM code |
| Direct message send | <5µs | Single-machine, same BEAM |
| GenServer.call | <20µs | Request-reply |
| gRPC roundtrip | <50ms | Includes network latency |
| Max concurrent services | 500+ | Hundreds, not thousands |
| Memory per service | ~2-5MB baseline | Plus heap for data |
| System uptime | 99.99% | 4 min/month downtime |

---

## 15. Development Roadmap

### **Phase 1: Foundation (Weeks 1-4)**

- [ ] Set up Elixir project, mix configuration
- [ ] Implement Solo.Kernel with root supervisor tree
- [ ] Create System, Driver, User supervisor hierarchy
- [ ] Implement basic startup/shutdown
- [ ] Write supervisor tree tests

### **Phase 2: Capabilities & Security (Weeks 5-8)**

- [ ] Implement Solo.Capability (unforgeable tokens)
- [ ] Create Solo.AttenuatedService wrapper
- [ ] Build capability grant/revoke logic
- [ ] Test isolation guarantees (property-based tests)
- [ ] Documentation on capability model

### **Phase 3: Service Deployment (Weeks 9-12)**

- [ ] Implement Solo.ServiceDeployer
- [ ] Support Elixir source code compilation
- [ ] Support BEAM bytecode loading
- [ ] Support external binary execution
- [ ] Sub-100ms startup optimization

### **Phase 4: gRPC API (Weeks 13-16)**

- [ ] Generate gRPC code from proto
- [ ] Implement Deploy RPC endpoint
- [ ] Implement Status, Kill, Watch endpoints
- [ ] Implement GrantCapability, Update endpoints
- [ ] gRPC error handling & streaming

### **Phase 5: Resource Management (Weeks 17-20)**

- [ ] Implement resource limits (memory, processes)
- [ ] Add CPU accounting via reductions
- [ ] Message queue monitoring
- [ ] Resource violation alerts
- [ ] Load testing and tuning

### **Phase 6: Persistence (Weeks 21-24)**

- [ ] ETS-based state management
- [ ] RocksDB integration
- [ ] State snapshotting/restoration
- [ ] Persistence configuration
- [ ] Tests for state recovery

### **Phase 7: Observability (Weeks 25-28)**

- [ ] Prometheus metrics export
- [ ] Pluggable observability backends
- [ ] Audit logging (local file backend)
- [ ] Service status dashboard (future)
- [ ] Distributed tracing (future)

### **Phase 8: Hot Reload & Updates (Weeks 29-32)**

- [ ] Kernel hot-reload via code_change
- [ ] Rolling update strategy
- [ ] Canary deployment
- [ ] Blue-green deployment
- [ ] Rollback mechanism

### **Phase 9: Reliability Hardening (Weeks 33-36)**

- [ ] Comprehensive error handling
- [ ] Crash recovery testing
- [ ] Graceful shutdown testing
- [ ] Chaos engineering tests
- [ ] Performance profiling & optimization

### **Phase 10: Documentation & MVP Release (Weeks 37-40)**

- [ ] Complete API documentation
- [ ] Example services (HTTP server, pipeline)
- [ ] Deployment guide
- [ ] Security model documentation
- [ ] Docker image & compose files
- [ ] MVP release (v0.1.0)

---

## 16. Open Questions for Implementation

1. **Erlang Distribution for clustering:** Should we enable cookie-based auth immediately, or wait until multi-machine is needed?

2. **Persistence** key format: What key naming scheme for auto-persisted ETS entries? (e.g., `:namespace:key` or nested maps?)

3. **Error recovery**: When a service crashes, should it automatically restart, or require explicit restart request?

4. **Memory measurement**: Use `Process.info/2` for memory, or more sophisticated GC accounting?

5. **gRPC concurrency**: How many concurrent gRPC handlers? (Default: num_schedulers * 2)

---

## 17. Success Metrics (MVP)

- [ ] 99.99% uptime in 24-hour test
- [ ] Sub-100ms service startup
- [ ] 500+ concurrent services stable
- [ ] Isolation verified with property tests + chaos tests
- [ ] Zero memory leaks detected
- [ ] Graceful recovery from all tested failures
- [ ] Comprehensive audit log for all operations
- [ ] Documentation complete & examples working

---

## Summary

**Solo** is a purpose-built, actor-based user-level operating system for LLM agents. It combines:

- **Erlang/OTP's reliability** (99.99% uptime, fault tolerance)
- **Capability-based security** (unforgeable references, attenuation)
- **Sub-100ms deployment** (BEAM bytecode pre-compilation)
- **Fine-grained resource control** (CPU, memory, process limits)
- **Multi-tier architecture** (system vs user services)
- **Zero-downtime updates** (rolling, canary, blue-green)
- **Complete auditability** (mandatory logging)

**Target outcome:** LLM agents can request services with **bulletproof isolation guarantees** and **automatic failure recovery**, giving agents the reliability and security they need for critical workloads.

---

**Document Version:** 1.0  
**Date:** 2026-02-08  
**Status:** Ready for Implementation Phase 1
