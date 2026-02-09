# SOLO Design Summary - One-Page Reference

## What is Solo?

A user-level operating system in Elixir for LLM agents to deploy services with:
- **Bulletproof isolation** (actor model + capability tokens)
- **99.99% reliability** (supervisor trees + automatic recovery)
- **Sub-100ms deployment** (BEAM bytecode)
- **Fine-grained access control** (capability-based security)

## Core Architecture

```
gRPC API (Port 50051)
    ↓
Capability Manager → Unforgeable Tokens
    ↓
Service Deployer → [Elixir Code | BEAM | Binary]
    ↓
Process Supervisor Tree
    ├── System Services (Audit, Registry, Monitor)
    ├── Hardware Drivers (Filesystem, Network)
    └── User Services (LLM-Deployed)
    ↓
Resource Limits (Memory, Processes, CPU)
    ↓
Erlang/OTP Runtime (BEAM VM)
```

## Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Language | Elixir | Actor model + OTP reliability |
| Deployment | Docker | Single machine, multi-machine ready |
| API | gRPC | Typed, performant, language-agnostic |
| Scheduling | BEAM default | Proven, preemptive, battle-tested |
| Security | Capability-based | Unforgeable references + attenuation |
| Clustering | Independent instances | Distributed eventual consistency |
| Code signing | TLS connection only | Simpler MVP, can add later |
| Updates | Rolling/Canary/Blue-Green | Zero-downtime deployments |

## Three Capability Layers

### Layer 1: Unforgeable Process References
- Elixir PIDs are cryptographically unforgeable
- Only kernel can issue them
- Services get only the PIDs they're granted

### Layer 2: Capability Tokens
- Wrap PID with permissions (read, write, execute)
- Time-limited (expiry)
- Revocable
- Prevent confused deputy attacks

### Layer 3: OS-Level Isolation (Future)
- Seccomp syscall filters
- Resource limits (cgroups)
- Pledge/unveil restrictions

## Three Service Deployment Modes

### Mode 1: Elixir Source Code
```elixir
code = "defmodule MyService do ... end"
deploy(code, :elixir_source)  # ~50-200ms startup
```

### Mode 2: BEAM Bytecode (Fast)
```
deploy(beam_binary, :beam_bytecode)  # ~5-10ms startup
```

### Mode 3: External Binary
```
deploy("/opt/bin/service", :external_binary)  # Language agnostic
```

## Two-Tier Service Model

### System Services (SLA: 99.99%)
- Kernel-critical (filesystem, audit, monitor)
- Get priority scheduling
- Larger resource budgets
- Can't be killed by user services

### User Services (SLA: Best-effort)
- LLM-deployed, application-facing
- Resource-limited
- Can be killed/restarted
- Isolated from each other

## gRPC API (8 Core Operations)

```protobuf
Deploy(code, capabilities, resources)      → ServicePID
Status(service_id)                        → Status, Memory, CPU
Kill(service_id, force)                   → OK
Watch(service_id)                         → Stream [Logs, Metrics, Events]
GrantCapability(service, permission, ttl) → CapToken
List(filter)                              → [Services]
Update(service, new_code, strategy)       → UpdateStatus
Shutdown(timeout)                         → OK
```

## Supervisor Hierarchy

```
Root (:one_for_one)
├─ System (:rest_for_one) [Audit, Registry, Monitor]
├─ Drivers (:one_for_one) [Filesystem, Network]
├─ User Services (:one_for_one) [User1, User2, ...]
└─ gRPC Server
```

**Why this structure:**
- Root: Isolated failure domains
- System: Ordered startup (Audit→Registry→Monitor)
- Drivers: Independent restart, no cascade
- User: Complete isolation between services

## Resource Isolation

Per-service limits (configurable):
```
max_processes: 100           # Child processes
max_memory_bytes: 4GB        # Per-process heap
cpu_shares: 1024             # Relative allocation
message_queue_limit: 10k     # Alert threshold
startup_timeout_ms: 100      # Must start in 100ms
shutdown_timeout_ms: 30s     # Graceful shutdown window
limit_exceeded_action: :kill|:throttle|:warn
```

## Service-to-Service Communication

### Direct Send (Fastest, ~1µs)
```elixir
send(service_b_pid, {:request, data})
```

### GenServer.call (Sync, ~20µs)
```elixir
GenServer.call(service_b_pid, {:compute, data}, timeout: 5000)
```

### Registry Lookup (Discovery, ~50µs)
```elixir
{:ok, pid} = Registry.lookup(Solo.Registry, "service_b")
GenServer.call(pid, {:compute, data})
```

## Observability & Audit (Mandatory)

**Metrics (Prometheus):**
- `solo_deployment_count` - Deployments
- `solo_active_services` - Running count
- `solo_service_memory_bytes` - Per-service memory
- `solo_service_startup_ms` - Startup latency
- `solo_grpc_request_duration_ms` - API latency

**Audit Log (All events):**
- Deployments (code, capabilities, resources)
- Terminations (reason, exit code)
- Capability grants/revokes
- Resource violations
- Shutdowns

**Pluggable backends:** Local file, Syslog, HTTP webhook, etc.

## Deployment Strategies

### Rolling Update
```
[V1, V1, V1] → [V2, V1, V1] → [V2, V2, V1] → [V2, V2, V2]
```
Configurable: `max_surge`, `max_unavailable`

### Canary Deployment
```
[V2(10%), V1(90%)] → [V2(30%), V1(70%)] → [V2(100%)]
```
Auto-rollback on metrics failure

### Blue-Green Deployment
```
BLUE: [V1, V1, V1] ← Active
GREEN: [V2, V2, V2] ← Warming
(switch) → GREEN: [V2, V2, V2] ← Active
          BLUE: [V1, V1, V1] ← Draining
```
Instant switchover, easy rollback

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Service startup | <100ms p99 | Pre-compiled BEAM |
| Direct message send | <5µs | Same machine |
| GenServer.call | <20µs | Synchronous RPC |
| gRPC roundtrip | <50ms | Network included |
| Max services | 500+ | Hundreds, not thousands |
| Memory per service | 2-5MB baseline | Plus data heap |
| System uptime | 99.99% | 4 min/month downtime |

## Threat Model Coverage

| Threat | Layer | Strength |
|--------|-------|----------|
| Service memory access | Actor isolation | ⭐⭐⭐⭐⭐ |
| Confused deputy | Capability tokens | ⭐⭐⭐⭐⭐ |
| Privilege escalation | Attenuation wrapper | ⭐⭐⭐⭐ |
| Resource DoS | Limits + monitoring | ⭐⭐⭐⭐ |
| Syscall abuse | Seccomp (future) | ⭐⭐⭐ |
| Process crashes | Supervisor trees | ⭐⭐⭐⭐⭐ |

## Hot Reload & Kernel Updates

Solo can update kernel code without full restart:

1. Compile new kernel code
2. Load into sandbox process
3. Run tests on sandbox
4. Swap via `:code.load_file/1`
5. Trigger `code_change/3` callbacks
6. Services keep running, system doesn't restart

## Development Timeline

```
Phase 1  (Weeks 1-4):   Foundation (supervisor tree)
Phase 2  (Weeks 5-8):   Security (capabilities)
Phase 3  (Weeks 9-12):  Deployment (code loading)
Phase 4  (Weeks 13-16): gRPC API
Phase 5  (Weeks 17-20): Resource management
Phase 6  (Weeks 21-24): Persistence
Phase 7  (Weeks 25-28): Observability
Phase 8  (Weeks 29-32): Hot reload & updates
Phase 9  (Weeks 33-36): Reliability hardening
Phase 10 (Weeks 37-40): Documentation & MVP release

Total: ~40 weeks (9-10 months) for full MVP
```

## MVP Success Criteria

- ✅ 99.99% uptime (≤4 min downtime in 24h)
- ✅ Sub-100ms service startup
- ✅ 500+ concurrent services stable
- ✅ Zero isolation violations (property + chaos tests)
- ✅ No memory leaks
- ✅ Automatic failure recovery
- ✅ Complete audit trail
- ✅ Comprehensive documentation

## Why This Architecture?

**For LLM Agents:**
- Deploy services instantly (<100ms)
- Strong isolation guarantees (no cross-contamination)
- Automatic recovery (99.99% uptime)
- Fine-grained access control (what services can do)
- Simple gRPC API (language-agnostic)

**For Operations:**
- Zero-downtime updates (rolling/canary/blue-green)
- Complete observability (metrics + audit logs)
- Easy debugging (process trees, supervisor status)
- Resource control (prevent runaway services)
- Hot kernel updates (no system restart needed)

**For Security:**
- Unforgeable capabilities (no fake access tokens)
- Attenuation (service can only do granted operations)
- Revocation (can immediately revoke access)
- Audit trail (every operation logged)
- OS-level isolation (future: seccomp + namespaces)

## Next Steps

1. ✅ **Design complete** (you are here)
2. ⏭️ **Phase 1:** Create mix project, supervisor tree
3. ⏭️ **Setup GitHub repo** with design docs
4. ⏭️ **Configure CI/CD** for testing
5. ⏭️ **Begin implementation** week 1

---

## Quick Links

- **Design Doc:** `solo_design_complete.md` (40 sections, comprehensive)
- **Checklist:** `solo_implementation_checklist.md` (phase-by-phase tasks)
- **Project Structure:** `solo_project_structure.md` (directory layout + templates)
- **This Summary:** `SOLO_DESIGN_SUMMARY.md` (one-page reference)

---

**Solo is ready to build.** All design decisions are made, architecture is solid, and implementation roadmap is clear. 

**Ready to start Phase 1?** 🚀
