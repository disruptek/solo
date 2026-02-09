# SOLO — Definitive Build Plan

**This document supersedes all previous phase plans, checklists, and roadmaps.**

**Date:** 2026-02-08
**Status:** Final

---

## What We're Building

Solo is a user-level operating system in Elixir. LLM agents deploy services into it via gRPC. Services run as supervised Erlang processes with capability-based access control, resource limits, and a replayable event store.

## What We Cut

| Feature | Reason |
|---------|--------|
| Pipelines | Convenience layer; agents compose services themselves |
| Adaptive trust / earned capabilities | Speculative; static capabilities are sufficient |
| Rolling / canary / blue-green deploys | Kubernetes thinking; BEAM hot swap + simple replace covers it |
| Drivers (filesystem, network, hardware) | Services access Linux directly; add as hardening layer later |
| RocksDB | C NIF; kernel crash risk. CubDB (pure Elixir) replaces it |
| Rust NIFs | Zero NIFs in MVP; add only for proven bottlenecks |
| Kernel persistence | Ephemeral for now; agents re-deploy after restart |
| User service persistence | Deferred; services manage their own state |
| BEAM bytecode deployment (Phase 2) | Start with Elixir source only; add bytecode loading in hardening phase |
| External binary deployment (Phase 2) | Start with Elixir source only; add port-based binaries in hardening phase |
| Code analyzer (Phase 2) | Not needed immediately; add as hardening. AtomMonitor is the runtime safety net |

## What Stays

The system we're building has these components, in dependency order:

```
1. CubDB (persistence engine)
2. Event Store (replayable log, backed by CubDB)
3. Supervisor Tree (hierarchical: root → tenant → service)
4. Atom Monitor (runtime atom table safety)
5. Service Deployer (Elixir source compilation + spawn)
6. Registry (service discovery)
7. gRPC Gateway (mTLS, protobuf, the external API)
8. Capabilities (tokens, attenuation, permission checking)
9. Resource Monitor (memory, CPU, process count)
10. Backpressure (mailbox monitor, circuit breakers, load shedding)
11. Hot Swap (live code replacement with rollback)
12. Vault (encrypted secrets)
13. Observability (telemetry, metrics, pluggable backends)
```

---

## Dependency Graph

```
CubDB
  └─→ Event Store
        ├─→ Supervisor Tree
        │     └─→ Service Deployer (Elixir source only)
        │           └─→ gRPC Gateway (mTLS)
        │                 ├─→ Capabilities
        │                 ├─→ Resource Monitor + Backpressure
        │                 ├─→ Hot Swap
        │                 ├─→ Vault
        │                 └─→ Observability
        ├─→ Atom Monitor
        └─→ Registry
```

Everything above the line it connects to must exist before it can be built.

---

## Build Phases

### Phase 1: The Skeleton
**Goal:** Solo boots, logs events, and you can poke it from iex.
**Deliverable:** A running OTP application with supervisor tree and event store.

**Build order:**

1. **Mix project setup**
   - `mix new solo --sup`
   - Dependencies: `cubdb`, `telemetry`, `x509`, `stream_data`, `credo`, `dialyxir`
   - Do NOT add gRPC deps yet (they're heavy and slow compilation)
   - Config files for dev/test/prod
   - Mix release configuration

2. **Solo.Event** — the event struct
   - Fields: id (monotonic), timestamp, wall_clock, tenant_id, event_type, subject, payload, causation_id
   - This is a plain struct with no behaviour
   - It's the lingua franca of the whole system

3. **Solo.EventStore** — append-only replayable log
   - GenServer backed by CubDB
   - `emit(event_type, payload)` — append an event
   - `stream(opts)` — stream events with filters (tenant, service, time range)
   - `last_id()` — current sequence number
   - Monotonic IDs (not UUIDs — ordered, gap-free)
   - Async writes via `GenServer.cast` (audit log must not be a bottleneck)
   - Starts first in the system supervisor

4. **Supervisor tree**
   - `Solo.Application` — OTP application entry point
   - `Solo.Kernel` — root supervisor (`:one_for_one`)
   - `Solo.System.Supervisor` — system services (`:rest_for_one`)
     - EventStore is the first child
     - AtomMonitor is the second child (placeholder for now)
     - Registry is the third child
   - `Solo.Tenant.Supervisor` — DynamicSupervisor for tenant trees
   - No driver supervisor (drivers are cut)

5. **Solo.Registry** — thin wrapper around Elixir's `Registry`
   - Register services by `{tenant_id, service_id}`
   - Lookup by name
   - List all services for a tenant
   - This is NOT a GenServer — it's a module wrapping `Registry` functions

6. **Solo.AtomMonitor** — GenServer, periodic check
   - Check `:erlang.system_info(:atom_count)` every 5 seconds
   - Emit events at 80% and 90% thresholds
   - At 90%, log critical warning (killing services comes later when deployer exists)

**Tests:**
- Application boots and supervisor tree is alive
- EventStore appends and streams events correctly
- EventStore survives restart (CubDB persists to disk)
- Registry registers and looks up services
- AtomMonitor detects high atom usage (mock `:erlang.system_info`)

**What you can do when this is done:**
- Start solo with `iex -S mix`
- Emit events: `Solo.EventStore.emit(:test, %{msg: "hello"})`
- Stream events: `Solo.EventStore.stream() |> Enum.to_list()`
- See the supervisor tree: `:observer.start()`

---

### Phase 2: Deploy and Run
**Goal:** Deploy Elixir source code as a supervised service from iex. Kill it. See events.
**Deliverable:** The core loop works: deploy → run → observe → kill.

**Build order:**

1. **Solo.Deployment.Compiler** — compile Elixir source
   - Compile with `Code.compile_string/2`
   - Namespace user modules to prevent collisions (prefix with `Solo.User.{tenant_id}.`)
   - Return `{:ok, [{module, bytecode}]}` or `{:error, reason}`
   - No static analysis yet — that comes in Phase 8

2. **Solo.Tenant.ServiceSupervisor** — per-service supervisor
   - Wraps the user's service process
   - Configurable `max_restarts` / `max_seconds`
   - Emits events on start, crash, restart

3. **Solo.Deployment.Deployer** — the core deployment GenServer
   - `deploy(spec)` → compile → start under tenant supervisor
   - `kill(tenant_id, service_id, opts)` → graceful or force
   - `status(tenant_id, service_id)` → process info
   - `list(tenant_id)` → all services for a tenant
   - Only accepts `format: :elixir_source` (other formats added in Phase 8)
   - Creates tenant supervisor on first deploy for that tenant
   - Emits events for every operation
   - Tracks deployed services in its own state (ephemeral — lost on restart)

**Tests:**
- Deploy Elixir source code, verify process is running
- Kill a service, verify it's gone
- Kill a service with force, verify immediate death
- Service crashes → supervisor restarts it → events emitted
- Tenant isolation: deploy under two tenants, kill one, other survives
- Restart storm: service that crashes on init, verify max_restarts triggers
- Deploy with invalid Elixir source, verify clean error

**What you can do when this is done:**
```elixir
iex> Solo.Deployment.Deployer.deploy(%{
  tenant_id: "agent_1",
  service_id: "my_service",
  code: ~S"""
    defmodule MyService do
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
      def init(:ok), do: {:ok, %{count: 0}}
      def handle_call(:ping, _from, state), do: {:reply, :pong, state}
    end
  """,
  format: :elixir_source
})
{:ok, #PID<0.234.0>}

iex> Solo.EventStore.stream() |> Enum.map(& &1.event_type)
[:service_deployed, :service_started]

iex> Solo.Deployment.Deployer.kill("agent_1", "my_service")
:ok

iex> Solo.EventStore.stream() |> Enum.map(& &1.event_type)
[:service_deployed, :service_started, :service_killed]
```

---

### Phase 3: The API
**Goal:** Agents can interact with solo over gRPC with mTLS.
**Deliverable:** Deploy, status, kill, list, watch — all working over the wire.

**Build order:**

1. **Add gRPC dependencies**
   - `grpc`, `protobuf`, `google_protos`
   - This is a separate step because gRPC deps are heavy

2. **Proto definitions** — `proto/solo/v1/solo.proto`
   - Start with a MINIMAL proto:
     - `Deploy`, `Status`, `Kill`, `List`, `Watch`, `Shutdown`
   - Do NOT include capabilities, vault, hot swap, or update RPCs yet
   - Keep the proto clean and small; extend it later

3. **Solo.Security.MTLS** — certificate management
   - On first boot, generate a CA cert + server cert using `:x509`
   - Store in a configurable directory (default: `./data/certs/`)
   - Provide a mix task to generate client certs: `mix solo.gen_cert agent_1`
   - Extract tenant_id from client certificate CN

4. **Solo.Gateway** — gRPC server
   - Bind to configurable port (default 50051)
   - Require mTLS (verify client cert)
   - Extract tenant_id from cert on every request
   - Route to Deployer
   - `Watch` streams events from EventStore filtered by tenant

5. **Graceful shutdown**
   - Trap SIGTERM in the application
   - Stop accepting new gRPC connections
   - Drain in-flight requests (30s timeout)
   - Shutdown supervisor tree
   - Exit cleanly

**Tests:**
- gRPC Deploy call creates a running service
- gRPC Status returns process info
- gRPC Kill stops the service
- gRPC List returns services for the authenticated tenant
- gRPC Watch streams events in real-time
- Connection without valid client cert is rejected
- Tenant A cannot see or kill Tenant B's services
- SIGTERM triggers graceful shutdown
- grpcurl smoke tests (documented in test script)

**What you can do when this is done:**
```bash
# Generate a client cert
mix solo.gen_cert agent_1

# Deploy a service
grpcurl -cert agent_1.pem -key agent_1-key.pem -cacert ca.pem \
  -d '{"service_id": "hello", "code": "...", "format": "ELIXIR_SOURCE"}' \
  localhost:50051 solo.v1.SoloKernel/Deploy

# Watch events
grpcurl -cert agent_1.pem -key agent_1-key.pem -cacert ca.pem \
  -d '{"service_id": "hello", "include_logs": true}' \
  localhost:50051 solo.v1.SoloKernel/Watch
```

**This is the first point where solo is genuinely usable by an LLM agent.**

---

### Phase 4: Capabilities
**Goal:** Services can only do what they're authorized to do.
**Deliverable:** Capability tokens gate access to kernel resources.

**Build order:**

1. **Solo.Capability** — token struct and validation
   - Struct: resource_ref, token_hash, permissions, expires_at, tenant_id, revoked?
   - `create/4`, `valid?/1`, `allows?/2`, `revoke/1`
   - Pure functions, no GenServer

2. **Solo.Capability.Manager** — GenServer for token lifecycle
   - `grant(tenant_id, resource, permissions, ttl)` → capability token
   - `revoke(token_hash)` → :ok
   - `verify(token, required_permission)` → :ok | {:error, reason}
   - Stores active tokens in ETS (fast lookup)
   - Emits events for grant/revoke/deny
   - Periodic sweep of expired tokens

3. **Solo.Capability.Attenuated** — permission-checking proxy
   - GenServer that wraps another process
   - Only forwards messages matching allowed operations
   - Returns `{:error, :forbidden}` for everything else
   - Emits events on deny

4. **Integrate capabilities into Deployer**
   - `DeployRequest` gains `initial_capabilities` field
   - Deployer creates attenuated proxies for requested resources
   - Passes proxy PIDs (not real PIDs) to user service
   - User service can only reach resources through proxies

5. **gRPC additions**
   - `GrantCapability` RPC
   - `RevokeCapability` RPC
   - Update proto, regenerate code

**Tests:**
- Capability token validates correctly
- Expired token is rejected
- Revoked token is rejected
- Attenuated proxy allows permitted operations
- Attenuated proxy blocks forbidden operations
- Service deployed with filesystem:read can read but not write
- Property test: no sequence of operations can forge a valid token
- Property test: attenuated proxy never allows unlisted operations

**What you can do when this is done:**
```elixir
# Deploy a service that can only read files
Solo.Deployment.Deployer.deploy(%{
  tenant_id: "agent_1",
  service_id: "reader",
  code: reader_code,
  format: :elixir_source,
  capabilities: [%{resource: "filesystem", permissions: ["read"], ttl_seconds: 3600}]
})
# Service receives a proxy PID, not the real filesystem PID
# Writes are blocked at the proxy level
```

---

### Phase 5: Resource Limits and Backpressure
**Goal:** No service can starve the system.
**Deliverable:** Memory, process, and mailbox limits enforced; circuit breakers work.

**Build order:**

1. **Solo.Resource.Limits** — configuration struct
   - max_memory_bytes, max_processes, cpu_shares, message_queue_limit
   - startup_timeout_ms, shutdown_timeout_ms
   - limit_exceeded_action: :kill | :throttle | :warn
   - Defaults for each field

2. **Solo.Resource.Monitor** — periodic monitoring GenServer
   - Polls all monitored services every 1-2 seconds
   - Checks: `Process.info(pid, [:memory, :message_queue_len, :reductions])`
   - Takes configured action when limits exceeded
   - Emits events for violations
   - Tracks per-service resource history (last N readings)

3. **Solo.Backpressure.CircuitBreaker** — per-service circuit breaker
   - States: closed → open → half_open → closed
   - Configurable failure threshold and reset timeout
   - Wraps GenServer.call with circuit breaker logic

4. **Solo.Gateway load shedding**
   - Track in-flight requests per tenant
   - Reject with `RESOURCE_EXHAUSTED` when at capacity
   - Configurable per-tenant limits

5. **Integrate into Deployer**
   - `DeployRequest` gains `resource_limits` field
   - Deployer passes limits to service supervisor
   - Service processes spawned with `max_heap_size`
   - Monitor starts tracking new services automatically

**Tests:**
- Service exceeding memory limit is killed (when action is :kill)
- Service exceeding memory limit gets warning (when action is :warn)
- Circuit breaker opens after N failures
- Circuit breaker resets after timeout
- Gateway rejects requests when tenant is at capacity
- Resource monitor emits events for violations
- Service with large mailbox is detected

---

### Phase 6: Hot Swap
**Goal:** Update a running service's code without restarting it.
**Deliverable:** Hot code replacement with automatic rollback.

**Build order:**

1. **Solo.HotSwap** — code replacement logic
   - `swap(tenant_id, service_id, new_code, opts)` → :ok | {:error, reason}
   - Compile new code through Compiler
   - Load new module version via `:code.load_binary/3`
   - Trigger `code_change/3` on the running process (via `:sys.change_code/4`)
   - Emit events

2. **Solo.HotSwap.Watchdog** — rollback timer
   - Monitor the swapped process for `rollback_window_ms` (default 30s)
   - If process crashes within window: purge new code, restart with old code
   - Emit rollback event

3. **gRPC additions**
   - `HotSwap` RPC
   - Update proto, regenerate code

4. **Simple replace** (stop + start)
   - `Solo.Deployment.Deployer.replace(tenant_id, service_id, new_spec)`
   - Kill old service, deploy new one
   - This is the "safe" path when hot swap is too risky

**Tests:**
- Hot swap updates a running service's behavior
- State is preserved across hot swap (via code_change)
- Crash within rollback window triggers automatic rollback
- Crash after rollback window does NOT trigger rollback
- Events emitted for swap and rollback
- Simple replace works (kill + redeploy)

---

### Phase 7: Vault and Observability
**Goal:** Services can access secrets safely; operators can monitor everything.
**Deliverable:** Encrypted secret store + telemetry-based metrics.

**Build order:**

1. **Solo.Vault** — encrypted secrets GenServer
   - `store(secret_name, value)` — encrypt with AES-256-GCM, store in CubDB
   - `fetch(secret_name, capability_token)` — verify capability, decrypt, return
   - Encryption key derived from a master key (configurable, from env var)
   - Every access emitted as event
   - Capability-gated: services need a vault capability to read secrets

2. **Solo.Observability** — telemetry integration
   - Attach telemetry handlers to key events:
     - `[:solo, :deploy, :start]` / `[:solo, :deploy, :stop]`
     - `[:solo, :grpc, :request, :start]` / `[:solo, :grpc, :request, :stop]`
     - `[:solo, :capability, :check]`
     - `[:solo, :resource, :violation]`
   - Default handler: log to Logger
   - Pluggable: users can attach their own handlers

3. **Solo.Observability.Prometheus** — optional metrics export
   - Counter: solo_deployments_total
   - Gauge: solo_active_services
   - Histogram: solo_deploy_duration_seconds
   - Histogram: solo_grpc_request_duration_seconds
   - Expose on configurable port (default 9090)

4. **gRPC additions**
   - `StoreSecret`, `FetchSecret` RPCs
   - Update proto

**Tests:**
- Store and fetch a secret
- Fetch without capability is denied
- Secret is encrypted at rest (inspect CubDB directly)
- Telemetry events fire for deploys, kills, gRPC requests
- Prometheus metrics increment correctly

---

### Phase 8: Hardening
**Goal:** Solo is reliable under adversarial conditions.
**Deliverable:** Chaos tests pass; 24-hour soak test clean.

**Build order:**

1. **Solo.Security.CodeAnalyzer** — AST-level static analysis (deferred from Phase 2)
   - Parse Elixir source with `Code.string_to_quoted/2`
   - Walk the AST looking for dangerous patterns:
     - `String.to_atom/1`, `List.to_atom/1`, `:erlang.binary_to_atom/2`
     - `:erlang.load_nif/2`, any Rustler references
     - `System.halt/1`, `System.cmd/3` (configurable)
     - `Node.spawn/2`, `:rpc.call/4` (prevent escape to other nodes)
   - Return `{:ok, ast}` or `{:error, [{line, reason}]}`
   - Integrate into Compiler: analyzer runs before compilation
   - Integrate into HotSwap: analyzer runs before hot swap

2. **Solo.Deployment.CodeLoader** — BEAM bytecode loading (deferred from Phase 2)
   - Solo.Security.NifGuard: validate bytecode has no NIF references
   - Load via `:code.load_binary/3`
   - Integrate into Deployer: accept `format: :beam_bytecode`

3. **Solo.Deployment.ExternalBinary** — Port-based external processes (deferred from Phase 2)
   - `Port.open({:spawn_executable, path}, opts)`
   - Capture stdout/stderr
   - Wrap in a GenServer that monitors the port
   - Integrate into Deployer: accept `format: :external_binary`

4. **Property-based tests** (StreamData)
   - No sequence of deploy/kill/grant/revoke operations violates isolation
   - No forged capability token is ever accepted
   - Attenuated proxies never allow unlisted operations
   - Resource limits are never exceeded without configured action firing

5. **Chaos tests**
   - Kill random services, verify supervisor restarts them
   - Kill tenant supervisors, verify tenant isolation
   - Flood a service with messages, verify backpressure activates
   - Exhaust memory in a service, verify configured action fires
   - Send invalid gRPC requests, verify clean error responses
   - Concurrent deploys from multiple tenants, verify no races

6. **Soak test**
   - Script that deploys/kills/hot-swaps services continuously for 24 hours
   - Monitor: memory usage, atom count, process count, event store size
   - Verify: no leaks, no crashes, no degradation

7. **ETS table leak detection**
   - Monitor `:ets.all()` count periodically
   - Alert if growing unboundedly
   - Add to AtomMonitor (rename to Solo.VMMonitor)

8. **File descriptor monitoring**
   - Check `/proc/self/fd` count periodically
   - Alert if approaching ulimit
   - Add to VMMonitor

**Tests:**
- All property tests pass
- All chaos tests pass
- 24-hour soak test completes with no leaks or crashes

---

## Final Module List

```
lib/solo/
├── application.ex                    # OTP application entry
├── kernel.ex                         # Root supervisor
│
├── system/
│   └── supervisor.ex                 # System services supervisor
│
├── tenant/
│   ├── supervisor.ex                 # DynamicSupervisor for tenants
│   └── service_supervisor.ex         # Per-service supervisor wrapper
│
├── event.ex                          # Event struct
├── event_store.ex                    # Append-only replayable log
│
├── deployment/
│   ├── deployer.ex                   # Core deploy/kill/status logic
│   └── compiler.ex                   # Elixir source compilation
│
├── security/
│   └── mtls.ex                       # Certificate generation and validation
│
├── capability/
│   ├── capability.ex                 # Token struct and validation
│   ├── manager.ex                    # Token lifecycle (grant/revoke)
│   └── attenuated.ex                 # Permission-checking proxy
│
├── resource/
│   ├── limits.ex                     # Limit configuration struct
│   └── monitor.ex                    # Periodic resource monitoring
│
├── backpressure/
│   ├── circuit_breaker.ex            # Per-service circuit breaker
│   └── load_shedder.ex              # Gateway-level request rejection
│
├── hot_swap/
│   ├── hot_swap.ex                   # Live code replacement
│   └── watchdog.ex                   # Rollback timer
│
├── vault.ex                          # Encrypted secrets store
├── vm_monitor.ex                     # Atom table, ETS, FD monitoring
│
├── gateway.ex                        # gRPC server + mTLS
│
├── observability/
│   ├── telemetry.ex                  # Telemetry event definitions + handlers
│   └── prometheus.ex                 # Optional Prometheus metrics export
│
└── registry.ex                       # Service discovery (wraps Elixir Registry)

# Added in Phase 8 (Hardening):
# ├── security/code_analyzer.ex        # AST-level dangerous pattern detection
# ├── security/nif_guard.ex            # BEAM bytecode NIF reference detection
# ├── deployment/code_loader.ex        # BEAM bytecode loading
# └── deployment/external_binary.ex    # Port-based external processes

proto/solo/v1/
└── solo.proto                        # gRPC service definitions

test/
├── solo/
│   ├── event_store_test.exs
│   ├── deployment/
│   │   ├── deployer_test.exs
│   │   └── compiler_test.exs
│   ├── security/
│   │   └── mtls_test.exs
│   ├── capability/
│   │   ├── capability_test.exs
│   │   └── attenuated_test.exs
│   ├── resource/
│   │   └── monitor_test.exs
│   ├── hot_swap/
│   │   └── hot_swap_test.exs
│   └── vault_test.exs
├── property_test.exs                 # Property-based isolation tests
├── chaos_test.exs                    # Chaos engineering tests
└── support/
    ├── test_service.ex               # Simple GenServer for testing
    └── fixtures.ex                   # Test data

# Added in Phase 8 (Hardening):
# ├── deployment/code_analyzer_test.exs
# ├── deployment/code_loader_test.exs
# └── deployment/external_binary_test.exs
```

---

## Dependencies (Final)

```elixir
defp deps do
  [
    # Persistence
    {:cubdb, "~> 2.0"},

    # gRPC (added in Phase 3)
    {:grpc, "~> 0.9"},
    {:protobuf, "~> 0.13"},

    # Security
    {:x509, "~> 0.8"},

    # Observability
    {:telemetry, "~> 1.2"},
    {:telemetry_metrics, "~> 0.6"},
    {:telemetry_poller, "~> 1.0"},

    # Testing
    {:stream_data, "~> 1.0", only: :test},
    {:mox, "~> 1.0", only: :test},

    # Code quality
    {:credo, "~> 1.7", only: [:dev, :test]},
    {:dialyxir, "~> 1.4", only: [:dev, :test]},
    {:ex_doc, "~> 0.34", only: :dev}
  ]
end
```

Note: version numbers should be verified against hex.pm at implementation time.
No `:rustler`, no `:rocksdb`, no `:sentry`, no `:prometheus_ex` (use telemetry instead).

---

## What Each Phase Unlocks

| Phase | What You Can Do |
|-------|----------------|
| 1 | Boot solo, emit events, inspect supervisor tree from iex |
| 2 | Deploy Elixir source services from iex, kill them, see events |
| 3 | **Deploy services over gRPC with mTLS** — solo is usable by agents |
| 4 | Services are capability-gated — multi-tenant security works |
| 5 | Resource limits enforced — no service can starve the system |
| 6 | Hot swap running services — zero-downtime updates |
| 7 | Secrets management + metrics — production-grade observability |
| 8 | Chaos/property/soak tested — production-grade reliability |

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| gRPC Elixir library is immature | Medium | High | Evaluate `grpc` library early in Phase 3; fall back to JSON/HTTP2 via Bandit if needed |
| Atom table exhaustion despite analysis | Low | Fatal | AtomMonitor catches runtime cases; CodeAnalyzer added in Phase 8; design interfaces for separate-node isolation later |
| CubDB performance insufficient | Low | Medium | Kernel writes are low-volume; if needed, switch to :dets or isolate RocksDB in a Port |
| Module name collisions between tenants | Medium | Medium | Namespace all user modules under `Solo.User.{tenant_id}.{service_id}` |
| BEAM bytecode validation incomplete | Medium | High | BEAM bytecode loading deferred to Phase 8 — not a risk until then |
| Hot swap state migration failures | Medium | Medium | Watchdog provides automatic rollback; simple replace is always available as fallback |

---

## Invariants (Never Violate These)

1. **No user-supplied NIFs in the kernel BEAM node.** Ever.
2. **Every state change emits an event.** No silent mutations.
3. **Tenant A cannot observe or affect Tenant B.** Enforced by supervisor hierarchy + capability model.
4. **The gRPC endpoint is always authenticated.** mTLS from day one.
5. **Resource limits are always enforced.** No service runs without limits.
6. **The event store is append-only.** Events are never modified or deleted.
7. **Capabilities are the only way to access kernel resources.** No backdoors.

---

## Instructions for @coder

Each phase should be implemented as follows:

1. Read this document and the relevant sections of `solo_design_v1.1_addendum.md`
2. Create a feature branch named `phase-N-description`
3. Implement the modules in the order listed
4. Write tests as you go (not after)
5. Run `mix test`, `mix credo`, `mix dialyzer`, `mix format`
6. Commit with a clear message describing what was built
7. When the phase deliverable is met (the "what you can do" section), the phase is done

Do NOT:
- Add features not listed in the current phase
- Skip tests
- Add dependencies not listed in this document
- Build "infrastructure" that isn't needed yet
- Over-abstract (no behaviours unless two implementations exist)

DO:
- Keep modules small and focused
- Use `@moduledoc` and `@doc` on every public function
- Use typespecs on every public function
- Emit events for every significant operation
- Write the simplest code that works
- Ask questions when the design is ambiguous
