# Phase 9: Persistence & State Recovery - IMPLEMENTATION PLAN

**Status:** Plan Mode (Read-Only)  
**Duration:** 2-3 weeks  
**Impact:** Production-Ready with Zero Data Loss

---

## Executive Summary

Solo currently loses all deployed services on restart because service metadata is stored only in memory. This plan introduces:

1. **Event Replay Recovery** - Replay `service_deployed` events on startup to restore services
2. **Capability Token Persistence** - Store tokens to CubDB for cross-restart access
3. **Graceful Shutdown** - Handle SIGTERM to flush pending operations naturally
4. **State Verification** - Check consistency between recovered state and persisted events

**Key Design:** Leverage existing EventStore as the source of truth for recovery.

---

## Current State (v0.2.0)

### ✅ Already Persistent
- EventStore (CubDB at `./data/events`) - append-only audit log
- Vault (CubDB at `./data/vault`) - encrypted secrets
- ServiceRegistry metadata (TTL-based ephemeral data)

### ❌ Lost on Restart
- Deployed services (in-memory PID mapping)
- Service metadata and specs
- Capability tokens (ETS table)
- Service registry entries (if they have TTL)

### Problem Scenario
```
1. Deploy service: {:ok, #PID<0.123.0>}
2. System crashes / manual shutdown
3. System restarts
4. Service is gone, agent has no way to recover it
5. Must manually redeploy service
```

---

## Solution Architecture

### Component 1: Service Recovery via Event Replay

**File:** `lib/solo/recovery/replayer.ex` (NEW)

**Concept:**
```
On Startup:
1. Read all :service_deployed events from EventStore
2. For each event, extract deployment spec
3. Redeploy service with original spec
4. Verify each recovery against EventStore
5. Handle any :service_killed events (don't recover these)
```

**Implementation:**
```elixir
defmodule Solo.Recovery.Replayer do
  @moduledoc """
  Replay deployment events to recover services after crash.
  
  Key invariant: If :service_killed event exists for a service,
  don't recover it (service was intentionally stopped).
  """
  
  def replay_deployments do
    # 1. Get all :service_deployed events
    # 2. Group by tenant_id + service_id
    # 3. For each service: find latest deployment
    # 4. Check if :service_killed exists after latest :service_deployed
    # 5. If killed: skip; if not: redeploy with original spec
    # 6. Return: {:ok, count} or {:error, reason}
  end
  
  def verify_recovery do
    # Compare current deployed services against EventStore events
    # Return inconsistencies for logging/alerting
  end
end
```

**Data Flow:**
```
EventStore Events                Registry (Memory)
    │                                │
    ├─ :service_deployed (id=1)     │
    │  tenant: "a1"                  │
    │  service: "svc1"               │
    │  code: "defmodule..."          ├─ service_deployed event replayed
    │                                │
    ├─ :service_deployed (id=3)      ├─ service re-created: PID 123
    │  tenant: "a1"                  │
    │  service: "svc2"               ├─ svc2 re-created: PID 456
    │                                │
    ├─ :service_killed (id=5)        │
    │  tenant: "a1"                  ├─ svc3 NOT recovered (killed event exists)
    │  service: "svc3"               │
    │                                │
    EventStore DB                    Recovered State
```

**Startup Integration:**

Current startup in `Solo.System.Supervisor.init/1`:
```elixir
# Before (Phase 2)
children = [
  {Solo.EventStore, [db_path: "./data/events"]},
  {Solo.AtomMonitor},
  {Solo.Registry},
  {Solo.Deployment.Deployer}  # Starts empty
]

# After (Phase 9)
children = [
  {Solo.EventStore, [db_path: "./data/events"]},
  {Solo.AtomMonitor},
  {Solo.Registry},
  {Solo.Deployment.Deployer},
  {Solo.Recovery.Replayer, restart: :temporary}  # Runs once, exits
]
```

**Tasks:**
- [ ] Create `Solo.Recovery.Replayer` module
- [ ] Implement `replay_deployments/0` function
- [ ] Implement `verify_recovery/0` function
- [ ] Write tests for recovery with various event sequences
- [ ] Add to startup sequence in `Solo.System.Supervisor`
- [ ] Add logging/telemetry for recovery process

**Effort:** 2-3 days | **Complexity:** Medium

---

### Component 2: Capability Token Persistence

**File:** `lib/solo/capability/token_store.ex` (NEW)

**Concept:**
```
Current (Phase 4):
  Token stored in ETS table → Lost on crash
  
After (Phase 9):
  Token stored in ETS + persisted to CubDB
  On startup: Restore tokens from CubDB to ETS
```

**Implementation:**
```elixir
defmodule Solo.Capability.TokenStore do
  @moduledoc """
  Persistent storage for capability tokens using CubDB.
  
  Tokens are stored with:
  - token_hash: SHA256 of token (for verification)
  - permission: :deploy, :kill, :read, etc.
  - tenant_id: which tenant owns token
  - granted_at: timestamp
  - expires_at: when token becomes invalid (or nil for no expiry)
  - metadata: arbitrary data
  """
  
  def store_token(token_hash, capability) do
    # Write to CubDB with key: {:token, token_hash}
    # Also maintain ETS for fast lookup
  end
  
  def restore_all_tokens do
    # On startup: scan CubDB for all tokens
    # For each non-expired token: restore to ETS
    # Skip expired tokens
    # Return count restored
  end
  
  def revoke_token(token_hash) do
    # Remove from both CubDB and ETS
  end
end
```

**Data Structure:**
```elixir
# Key in CubDB: {:token, token_hash}
# Value:
%{
  token_hash: "abc123...",
  permission: :deploy,
  tenant_id: "agent_1",
  granted_at: ~U[2026-02-09 14:30:00Z],
  expires_at: ~U[2026-02-10 14:30:00Z],  # or nil
  metadata: %{rate_limit: 10}
}
```

**Startup Integration:**

In `Solo.Capability.Manager.init/1`:
```elixir
# After ETS table is created, restore persisted tokens
def init([]) do
  ets_table = :ets.new(:capability_tokens, [...])
  {:ok, count} = Solo.Capability.TokenStore.restore_all_tokens(ets_table)
  Logger.info("Restored #{count} capability tokens")
  {:ok, %{ets: ets_table}}
end
```

**Tasks:**
- [ ] Create `Solo.Capability.TokenStore` module
- [ ] Implement `store_token/2` to write to both CubDB and ETS
- [ ] Implement `restore_all_tokens/1` for startup
- [ ] Update `Solo.Capability.Manager.grant/3` to call `TokenStore.store_token`
- [ ] Update `Solo.Capability.Manager.revoke/1` to call `TokenStore.revoke_token`
- [ ] Write tests for token persistence across restarts
- [ ] Add telemetry: token_restored, token_persisted events

**Effort:** 2-3 days | **Complexity:** Medium

---

### Component 3: Graceful Shutdown Handler

**File:** `lib/solo/shutdown/graceful_shutdown.ex` (NEW)

**Concept:**
```
Before (Phase 2):
  System crashes → data loss → recovery needed
  
After (Phase 9):
  SIGTERM received → Gracefully shutdown → No extra recovery needed
```

**Implementation:**
```elixir
defmodule Solo.Shutdown.GracefulShutdown do
  @moduledoc """
  Handle SIGTERM signal gracefully.
  
  Process:
  1. Receive SIGTERM
  2. Emit :system_shutdown_started event
  3. Wait for all pending GenServer.casts to complete (100ms timeout)
  4. Flush EventStore to disk
  5. Flush CubDB databases
  6. Emit :system_shutdown_complete event
  7. Exit normally (exit code 0)
  """
  
  def start_handler do
    # Register signal handler with :gen_event or direct signal handling
    # This is a one-shot listener, not a GenServer
  end
  
  def shutdown_sequence do
    # 1. Event: :system_shutdown_started
    # 2. Sleep 100ms for pending operations
    # 3. Flush EventStore
    # 4. Flush Vault
    # 5. Flush Token Store
    # 6. Event: :system_shutdown_complete
    # 7. System.halt(0)
  end
end
```

**Signal Handling Approach:**

Option A (Elixir 1.15+): Use `System.trap_signal/2`
```elixir
System.trap_signal(:sigterm, fn ->
  Logger.info("SIGTERM received, initiating graceful shutdown")
  Solo.Shutdown.GracefulShutdown.shutdown_sequence()
end)
```

Option B (Erlang): Use `:erl_signal_server` if available

**Tasks:**
- [ ] Create `Solo.Shutdown.GracefulShutdown` module
- [ ] Implement signal trap in `Solo.Kernel.start/2`
- [ ] Implement `shutdown_sequence/0` with timeouts
- [ ] Add EventStore.flush/0 method
- [ ] Add Vault flush integration
- [ ] Add Token Store flush integration
- [ ] Write tests for graceful shutdown
- [ ] Test cold start after graceful shutdown

**Effort:** 1-2 days | **Complexity:** Low-Medium

---

### Component 4: State Verification & Consistency Checking

**File:** `lib/solo/recovery/verifier.ex` (NEW)

**Concept:**
```
After recovery, verify that:
1. All recovered services match EventStore
2. No services exist without corresponding :service_deployed event
3. All :service_killed events are honored
4. Service counts match expected values
5. Log any inconsistencies for alerting
```

**Implementation:**
```elixir
defmodule Solo.Recovery.Verifier do
  @moduledoc """
  Verify consistency between recovered state and EventStore.
  
  Returns: {:ok, report} or {:error, inconsistencies}
  """
  
  def verify_consistency do
    # 1. Get all services from Registry
    # 2. Get all service_deployed events from EventStore
    # 3. Get all service_killed events
    # 4. Check:
    #    a. Every deployed service has a :service_deployed event
    #    b. Every :service_deployed event has corresponding service OR :service_killed
    #    c. No orphaned services
    #    d. Counts match
    # 5. Return report with any inconsistencies
  end
  
  def auto_fix_inconsistencies do
    # For detected inconsistencies:
    # - If service exists but no event: emit :service_deployed event
    # - If event exists but service gone: expect :service_killed event
    # - If both missing: log as error, don't auto-fix (manual review needed)
  end
end
```

**Tasks:**
- [ ] Create `Solo.Recovery.Verifier` module
- [ ] Implement `verify_consistency/0` function
- [ ] Implement consistency report generation
- [ ] Add telemetry events for verification results
- [ ] Call from `Solo.Recovery.Replayer` after recovery
- [ ] Write tests for various consistency scenarios

**Effort:** 1-2 days | **Complexity:** Low

---

## Implementation Roadmap

### Week 1: Foundation & Testing
- [ ] Design & agree on data structures
- [ ] Implement Component 1 (Event Replay)
  - [ ] `Solo.Recovery.Replayer` module
  - [ ] Replay logic and tests
  - [ ] Integration with Deployer
- [ ] Write comprehensive tests for:
  - [ ] Single service recovery
  - [ ] Multiple service recovery
  - [ ] Service kill scenarios
  - [ ] Event ordering edge cases

### Week 2: Tokens & Shutdown
- [ ] Implement Component 2 (Token Persistence)
  - [ ] `Solo.Capability.TokenStore` module
  - [ ] Integration with Capability.Manager
  - [ ] Token restore on startup
- [ ] Implement Component 3 (Graceful Shutdown)
  - [ ] Signal handler in Kernel
  - [ ] Shutdown sequence
  - [ ] Flush integration
- [ ] Write tests for:
  - [ ] Token persistence and recovery
  - [ ] Graceful shutdown scenarios
  - [ ] Force kill recovery

### Week 3: Verification & Polish
- [ ] Implement Component 4 (Verification)
  - [ ] Consistency checker
  - [ ] Auto-fix logic
- [ ] End-to-end integration tests:
  - [ ] Deploy → Crash → Recover → Verify
  - [ ] Multiple tenants scenario
  - [ ] Large event log (1000+ events)
- [ ] Documentation:
  - [ ] Update README with persistence guarantees
  - [ ] Add recovery operation guide
  - [ ] Document troubleshooting

---

## File Structure

```
lib/solo/
├── recovery/
│   ├── replayer.ex        (NEW) - Event replay engine
│   └── verifier.ex        (NEW) - Consistency verification
├── capability/
│   └── token_store.ex     (NEW) - Token persistence
└── shutdown/
    └── graceful_shutdown.ex (NEW) - SIGTERM handler

test/solo/
├── recovery/
│   ├── replayer_test.exs  (NEW)
│   └── verifier_test.exs  (NEW)
├── capability/
│   └── token_store_test.exs (NEW)
└── shutdown/
    └── graceful_shutdown_test.exs (NEW)
```

---

## Database Schema Changes

### New CubDB Keys

**EventStore (no changes):**
- Existing: `{:event, id}` → Event struct
- Existing: `:next_id` → counter

**Capability TokenStore (NEW):**
- Key: `{:token, token_hash}` → Token capability map
- Key: `{:tokens_by_tenant, tenant_id}` → Set of token hashes (for cleanup)
- Key: `{:token_meta, token_hash}` → Metadata (granted_at, expires_at, etc.)

**Vault (no changes):**
- Existing: `{:secret, tenant_id, secret_name}` → encrypted blob

---

## Recovery Guarantees

After Phase 9, Solo provides:

**✅ Zero Data Loss**
- Events persist to disk immediately (via CubDB)
- Services recover from EventStore on restart
- Tokens persist across restarts
- Secrets already persistent

**✅ Graceful Shutdown**
- SIGTERM handled cleanly
- Pending operations complete before shutdown
- CubDB flushes to disk
- No partial writes

**✅ Consistency**
- EventStore is source of truth
- Recovered state verified against events
- Inconsistencies detected and reported
- Auto-fix for non-critical issues

**✅ Performance**
- Recovery time: < 10 seconds for 1000 services
- No blocking startup operations
- Verification runs asynchronously

---

## Testing Strategy

### Unit Tests
- Event replay with various scenarios
- Token persistence and recovery
- Graceful shutdown handling
- Consistency verification

### Integration Tests
- Full recovery cycle: Deploy → Crash → Recover
- Multi-tenant recovery
- Large event log (1000+ events)
- Concurrent operations during recovery

### Stress Tests
- Rapid deploy/kill cycles
- Large number of tokens (10000+)
- Long-running system (72+ hours)
- Simulated crashes at various points

### Verification Tests
- Recovery produces identical state
- No duplicate services
- No orphaned processes
- All events accounted for

---

## Configuration & Environment Variables

### New Config Keys

```elixir
# config/config.exs
config :solo,
  # Recovery settings
  recovery_enabled: true,
  recovery_timeout_ms: 30000,      # Max time for recovery
  verify_recovery: true,            # Verify consistency
  
  # Token persistence
  token_persistence_enabled: true,
  token_cleanup_interval_ms: 3600000, # 1 hour
  
  # Graceful shutdown
  shutdown_timeout_ms: 5000,        # Time to complete pending ops
  log_shutdown_events: true
```

### Environment Variables

```bash
export SOLO_RECOVERY_ENABLED=true
export SOLO_RECOVERY_TIMEOUT_MS=30000
export SOLO_TOKEN_PERSISTENCE=true
export SOLO_SHUTDOWN_TIMEOUT_MS=5000
```

---

## Known Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| **Corrupted event log** | Services can't recover | Backup EventStore, implement checksum validation |
| **Recovery timeout** | Services not recovered | Set reasonable timeout, log partial recovery |
| **Token expiry during recovery** | Token lost if not persisted | Store token_hash + ttl together |
| **Concurrent deploy during recovery** | Race condition | Lock deployer during recovery, use sequencing |
| **Large event logs** | Recovery takes too long | Implement checkpointing (Phase 10) |
| **SIGTERM arrives during write** | Partial data | CubDB handles this, but add verification |

---

## Success Criteria

**✅ Phase 9 Complete When:**

1. **Services Persist**
   - [ ] Deploy service, crash system, service recovers
   - [ ] Multiple services recover correctly
   - [ ] Service state is identical post-recovery

2. **Tokens Persist**
   - [ ] Grant token, crash system, token still valid
   - [ ] Expired tokens not restored
   - [ ] Token count matches EventStore

3. **Graceful Shutdown**
   - [ ] SIGTERM handled without errors
   - [ ] No pending operations lost
   - [ ] EventStore flushed cleanly

4. **Consistency Verified**
   - [ ] Recovery verification runs successfully
   - [ ] No inconsistencies reported for normal scenarios
   - [ ] Inconsistencies detected for edge cases

5. **Testing**
   - [ ] All 163+ existing tests still pass
   - [ ] 40+ new tests for Phase 9
   - [ ] Integration tests for recovery scenarios
   - [ ] Stress tests pass (72+ hours running)

6. **Documentation**
   - [ ] README updated with persistence info
   - [ ] Operations guide for recovery
   - [ ] Troubleshooting guide
   - [ ] Recovery procedure documented

---

## Next Steps (After Phase 9)

Once Phase 9 is complete:

1. **Phase 10:** Performance optimization
   - Checkpointing for faster recovery
   - Benchmarking suite
   - Concurrent recovery

2. **Phase 11:** Advanced security
   - Rate limiting with persistence
   - Persistent capability metadata
   - Audit log retention policies

3. **Phase 13:** Clustering
   - Distributed EventStore
   - Cross-node recovery
   - Service migration

---

## Questions & Decisions

**Q: Should recovery be automatic or manual?**  
A: Automatic on startup. Services deploy immediately without user action. Errors logged.

**Q: What if deployment spec has changed between crashes?**  
A: Use original spec from event. User can hot-swap code if needed after recovery.

**Q: How to handle service code that no longer compiles?**  
A: Emit `:service_recovery_failed` event, log error, skip service, continue recovery.

**Q: Should capability tokens ever be recreated?**  
A: No. If token is lost, agent must re-grant. Tokens are not recoverable, only persisted existing ones.

**Q: What about secrets that were accessed during recovery?**  
A: Secrets already persistent via Vault. No changes needed.

---

## Contact & Feedback

This plan follows:
- **Elixir patterns:** GenServer, CubDB, Events
- **Solo architecture:** EventStore-centric, tenant isolation
- **Production practices:** Consistency verification, graceful shutdown, audit trails

For questions or suggestions, refer to project guidelines in README.md.
