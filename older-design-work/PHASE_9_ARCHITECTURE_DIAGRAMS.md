# Phase 9: Persistence Architecture Diagrams

## 1. System Recovery Flow (High Level)

```
┌─────────────────────────────────────────────────────────────────┐
│                    SYSTEM STARTUP                               │
└────────────────────────┬────────────────────────────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Solo.Kernel.start/2            │
        │  - Register signal handler      │
        │  - Start supervisors            │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Solo.System.Supervisor         │
        │  rest_for_one: (in order)       │
        │  1. EventStore (CubDB)          │
        │  2. AtomMonitor                 │
        │  3. Registry                    │
        │  4. Deployer                    │
        │  5. CapabilityManager           │
        │  6. LoadShedder                 │
        │  7. Vault                       │
        │  8. ServiceRegistry             │
        │  9. Telemetry                   │
        │  10. Gateway                    │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Deployer.init/1                │
        │  - Start temp registry          │
        │  - Ready for deployments        │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Recovery.Replayer (PHASE 9)    │
        │  restart: :temporary            │
        │  Runs once per startup          │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Capability.TokenStore.restore  │
        │  - Load tokens from CubDB       │
        │  - Restore to ETS table         │
        │  - Skip expired tokens          │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Recovery.Replayer.replay/0     │
        │  - Get :service_deployed events │
        │  - Redeploy each service        │
        │  - Skip if :service_killed      │
        │  - Emit recovery telemetry      │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  Recovery.Verifier.verify/0     │
        │  - Check consistency            │
        │  - Detect orphaned services     │
        │  - Auto-fix if possible         │
        │  - Emit verification report     │
        └────────────────┬────────────────┘
                         │
        ┌────────────────▼────────────────┐
        │  System Ready                   │
        │  - All services recovered       │
        │  - All tokens restored          │
        │  - Consistency verified         │
        │  - Accepting requests           │
        └─────────────────────────────────┘
```

---

## 2. Service Recovery Detailed Flow

```
STARTUP EVENT STORE

┌──────────────────────────────────────┐
│  EventStore (CubDB Disk)             │
├──────────────────────────────────────┤
│ ID | Type             | Payload      │
├──────────────────────────────────────┤
│  1 | :service_deployed| tenant: a1   │
│    |                  | service: s1  │
│    |                  | code: "..."  │
├──────────────────────────────────────┤
│  2 | :service_deployed| tenant: a1   │
│    |                  | service: s2  │
│    |                  | code: "..."  │
├──────────────────────────────────────┤
│  3 | :service_killed  | tenant: a1   │
│    |                  | service: s2  │
├──────────────────────────────────────┤
│  4 | :service_deployed| tenant: a1   │
│    |                  | service: s3  │
│    |                  | code: "..."  │
└──────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────┐
│  Recovery.Replayer                   │
│  1. Read events 1-4                  │
│  2. Group by tenant+service          │
│  3. Build recovery plan:             │
│     - s1: latest event = 1 (deploy)  │
│            no kill event             │
│            → RECOVER                 │
│     - s2: latest event = 2 (deploy)  │
│            event 3 = kill            │
│            → SKIP                    │
│     - s3: latest event = 4 (deploy)  │
│            no kill event             │
│            → RECOVER                 │
└──────────────────────────────────────┘
         │
         ├──────────────────┬──────────────────┐
         │                  │                  │
         ▼                  ▼                  ▼
    ┌────────────┐   ┌────────────┐   ┌────────────┐
    │ Deploy s1  │   │ Skip s2    │   │ Deploy s3  │
    │ code: "..."│   │ (killed)   │   │ code: "..."│
    │ PID: 123   │   │            │   │ PID: 456   │
    └────────────┘   └────────────┘   └────────────┘
         │                                    │
         └────────────────┬────────────────────┘
                          │
                          ▼
              ┌────────────────────────┐
              │ Registry (Memory)      │
              │ - s1: PID 123          │
              │ - s3: PID 456          │
              │ - s2: NOT recovered    │
              └────────────────────────┘
                          │
                          ▼
              ┌────────────────────────┐
              │ Verifier.verify        │
              │ - Check all recovered  │
              │ - Match vs events      │
              │ - No orphans           │
              │ - Report: OK           │
              └────────────────────────┘
```

---

## 3. Capability Token Persistence

```
BEFORE PHASE 9: Tokens Lost on Restart

Agent                    Solo System                    Memory (ETS)
  │                            │                             │
  ├──────── grant token ───────>│                             │
  │                      │      ├──────────────────────────>  │
  │                      │      │  Token: "abc123"            │
  │                      │      │  Permission: :deploy        │
  │                      │      │  ← Stored only in ETS       │
  │                      │      │                             │
  │<───────── token ────────────┤                             │
  │                      │      │                             │
  │                   CRASH!!!  │ ✗ All ETS tables lost
  │                             │ ✗ Token lost
  │                      RESTART │
  │                      │      ├─ New ETS created (empty)
  │                      │      │
  │                             │
  ├──────── verify token ───────>│
  │                      │      ├──────────────────────────>  │
  │                      │      │  Token: "abc123"            │
  │                      │      │  ✗ NOT IN ETS               │
  │                      │      │  → ERROR: Token not found   │
  │<───── ERROR ────────────────┤                             │
  │                      │                                    │
```

```
AFTER PHASE 9: Tokens Persist

Agent                    Solo System                    Memory (ETS)    Disk (CubDB)
  │                            │                             │              │
  ├──────── grant token ───────>│                             │              │
  │                      │      ├──────────────────────────>  │              │
  │                      │      │  Store in ETS              │              │
  │                      │      │  + Persist to CubDB ──────────────────>  │
  │                      │      │  Token: "abc123"            │  Token: "a" │
  │                      │      │  Permission: :deploy        │  Perm: :dep │
  │                      │      │                             │  Tenant: a1 │
  │<───────── token ────────────┤                             │              │
  │                      │      │                             │              │
  │                   CRASH!!!  │ ✗ ETS lost                 │ ✓ CubDB survives
  │                             │                             │              │
  │                      RESTART │                            │              │
  │                      │      ├─ New ETS created           │              │
  │                      │      ├──────────────────────────>  │              │
  │                      │      │                             │ ✓ Restore ──┤
  │                      │      │ Restore from CubDB ─────────┤ from disk   │
  │                      │      │  Token: "abc123"            │              │
  │                      │      │  Permission: :deploy        │              │
  │                      │      │                             │              │
  ├──────── verify token ───────>│                             │              │
  │                      │      ├──────────────────────────>  │              │
  │                      │      │  Token: "abc123"            │              │
  │                      │      │  ✓ IN ETS                   │              │
  │                      │      │  → SUCCESS                  │              │
  │<───── SUCCESS ──────────────┤                             │              │
  │                      │                                    │              │
```

---

## 4. Graceful Shutdown Sequence

```
Normal Operation:
  Solo.Kernel (running)
    │
    ├─ System.Supervisor
    │   ├─ EventStore (GenServer.cast)
    │   ├─ Deployer (GenServer.call/cast)
    │   ├─ CapabilityManager (GenServer.cast)
    │   └─ ...other services
    │
    └─ Tenant.Supervisor
        └─ Per-tenant: ServiceSupervisor
            └─ Services (GenServer)

Signal Received: SIGTERM
  │
  ▼
┌────────────────────────────────────────┐
│ GracefulShutdown.signal_handler        │
│ (registered via System.trap_signal)    │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ Emit: :system_shutdown_started         │
│ EventStore writes event                │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ Wait 100ms                             │
│ Let pending GenServer.cast complete    │
│ - EventStore flushes events            │
│ - Capability tokens persisted          │
│ - Vault encrypts secrets               │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ EventStore.flush()                     │
│ - Force CubDB.save()                   │
│ - Ensure all events on disk            │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ TokenStore.flush() (if needed)         │
│ - Ensure tokens flushed to disk        │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ Vault.flush()                          │
│ - Ensure secrets flushed               │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ Emit: :system_shutdown_complete        │
│ EventStore writes final event          │
└────────────────┬───────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────┐
│ System.halt(0)                         │
│ Exit code 0 = clean shutdown           │
│ Exit code 1 = error during shutdown    │
└────────────────────────────────────────┘
```

---

## 5. Consistency Verification Flow

```
After Recovery Completes:

┌──────────────────────────────────┐
│ EventStore (on disk)             │
├──────────────────────────────────┤
│ Events for tenant a1:            │
│ - :service_deployed: s1, s2, s3  │
│ - :service_killed: s2            │
│                                  │
│ Expected deployed services:      │
│ - s1 (deployed, not killed)      │
│ - s3 (deployed, not killed)      │
│ - s2 NOT (deployed but killed)   │
└──────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Registry (memory)                │
├──────────────────────────────────┤
│ Actual deployed services:        │
│ - s1: PID 123                    │
│ - s2: PID 456  ← EXTRA!          │
│ - s3: PID 789                    │
│                                  │
│ INCONSISTENCY DETECTED!          │
│ s2 deployed but should be killed │
└──────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Verifier.verify_consistency()    │
│ Status: WARNING                  │
│                                  │
│ Inconsistencies:                 │
│ 1. s2 exists but has             │
│    :service_killed event         │
│                                  │
│ Recommendations:                 │
│ - Kill service s2                │
│ - Or re-emit :service_deployed   │
│   if s2 was killed by mistake    │
└──────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Verifier.auto_fix()              │
│                                  │
│ Action: Kill s2 since killed     │
│ event exists in EventStore       │
│                                  │
│ Result: SUCCESS                  │
│ - s2 killed                      │
│ - Registry now consistent        │
└──────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────┐
│ Final State                      │
├──────────────────────────────────┤
│ Registry:                        │
│ - s1: PID 123  ✓                 │
│ - s3: PID 789  ✓                 │
│                                  │
│ EventStore:                      │
│ - Deployed: s1, s2, s3           │
│ - Killed: s2                     │
│                                  │
│ Status: CONSISTENT ✓             │
└──────────────────────────────────┘
```

---

## 6. Data Persistence Layout

```
DISK LAYOUT:
./data/
├── events/                    (CubDB - EventStore)
│   ├── lock.dets
│   ├── data.dets
│   └── (append-only log)
│
├── vault/                     (CubDB - Secrets)
│   ├── lock.dets
│   ├── data.dets
│   └── (encrypted secrets)
│
└── tokens/                    (NEW in Phase 9 - CubDB)
    ├── lock.dets
    ├── data.dets
    └── (capability tokens)

KEY STRUCTURES:

EventStore (events/):
  {:event, 1} → Event{type: :service_deployed, ...}
  {:event, 2} → Event{type: :service_deployed, ...}
  {:event, 3} → Event{type: :service_killed, ...}
  :next_id → 4

Vault (vault/):
  {:secret, "a1", "DB_PASSWORD"} → AES-256-GCM encrypted blob
  {:secret, "a1", "API_KEY"} → encrypted blob

TokenStore (tokens/ - NEW):
  {:token, "hash_abc123"} → %{
    token_hash: "abc123",
    permission: :deploy,
    tenant_id: "a1",
    granted_at: ~U[...],
    expires_at: ~U[...],
    metadata: %{}
  }
  {:tokens_by_tenant, "a1"} → #MapSet{"hash_abc", "hash_def"}
  {:token_meta, "hash_abc"} → %{created_at: ..., expires_at: ...}

MEMORY (ETS & GenServer State):

CapabilityManager ETS (:capability_tokens):
  "hash_abc123" → %{permission: :deploy, tenant: "a1", ...}

ServiceRegistry (GenServer state):
  %{
    "a1" => [
      %{service_id: "s1", pid: #PID<0.123.0>, ...},
      %{service_id: "s3", pid: #PID<0.456.0>, ...}
    ]
  }

Deployer (GenServer state):
  %{
    services: %{
      "a1" => %{
        "s1" => %{pid: #PID<0.123.0>, spec: %{...}},
        "s3" => %{pid: #PID<0.456.0>, spec: %{...}}
      }
    }
  }
```

---

## 7. Recovery Process Timeline

```
TIME    EVENT                                  COMPONENT
─────────────────────────────────────────────────────────────────────
 0ms    System starts                          Kernel
        │
 10ms   EventStore initialized                EventStore
        │  └─ Opens CubDB (./data/events)
        │
 30ms   Deployer initialized                  Deployer
        │  └─ Empty service list
        │
 50ms   Recovery.Replayer starts              Replayer
        │
 60ms   Read all events from EventStore       Replayer
        │  └─ 1000 events (< 5ms)
        │
 65ms   Plan recovery:                        Replayer
        │  └─ 150 services to recover
        │     Skip 5 killed services
        │     Recover 145 services
        │
 70ms   Deploy services 1-50                  Deployer
        │  └─ ~2ms each
        │
 180ms  Deploy services 51-145                Deployer
        │  └─ Compilation + startup
        │
 200ms  TokenStore.restore_tokens             TokenStore
        │  └─ Restore 500 tokens from CubDB
        │
 210ms  Verify recovery consistency           Verifier
        │  └─ Check all services match events
        │     Find 0 inconsistencies
        │
 220ms  System ready                          Kernel
        │  └─ Accept requests
        │
        Total startup time: 220ms
        Services recovered: 145
        Tokens restored: 500
        Inconsistencies: 0
```

---

## 8. Token Storage & Restoration

```
GRANT TOKEN (During Normal Operation):

Agent                         Solo                    Memory    Disk
  │                            │                       │         │
  ├──── grant(:deploy) ───────>│                       │         │
  │                      │      │                       │         │
  │                      │      ├─ Generate token ──>  │         │
  │                      │      │  "token_abc123"      │         │
  │                      │      │                       │         │
  │                      │      ├─ Hash token ───────> │         │
  │                      │      │  hash = SHA256(tok)  │         │
  │                      │      │                       │         │
  │                      │      ├─ Store in ETS ────> │         │
  │                      │      │  ETS["hash_abc"] =   │         │
  │                      │      │    {perm: :deploy}   │         │
  │                      │      │                       │         │
  │                      │      ├─ Persist to CubDB ─────────────> │
  │                      │      │  {:token, "hash_abc"} │         │
  │                      │      │                       │  CubDB: │
  │                      │      │                       │  {      │
  │                      │      │                       │    ...  │
  │                      │      │                       │  }      │
  │<────── token ──────────────┤                       │         │
  │                      │                              │         │


RESTORE TOKENS (On Startup):

Startup                       Recovery                Memory    Disk
  │                            │                       │         │
  ├─ Initialize CapabilityMgr ─>│                      │         │
  │                      │      │                       │         │
  │                      │      ├─ Create ETS ──────> │         │
  │                      │      │  Empty at first      │         │
  │                      │      │                       │         │
  │                      │      ├─ Call restore ──────────────>│
  │                      │      │                       │         │
  │                      │      │  Read CubDB (disk) ◄────────┤
  │                      │      │                       │  Read: │
  │                      │      │                       │  {:token,"a"│
  │                      │      │                       │  {:token,"b"│
  │                      │      │                       │         │
  │                      │      ├─ Check expiry ──────┤         │
  │                      │      │  Remove expired      │         │
  │                      │      │                       │         │
  │                      │      ├─ Insert in ETS ────> │         │
  │                      │      │  ETS["hash_abc"] =   │         │
  │                      │      │    {perm: :deploy}   │         │
  │                      │      │  ETS["hash_def"] =   │         │
  │                      │      │    {perm: :kill}     │         │
  │                      │      │                       │         │
  │<─ Ready ──────────────────┤                       │         │
  │  500 tokens restored      │                       │         │
```

---

## 9. Module Dependency Graph (Phase 9 Components)

```
                    ┌─────────────────────┐
                    │   Kernel.start/2    │
                    └──────────┬──────────┘
                               │
                ┌──────────────┼──────────────┐
                │                             │
                ▼                             ▼
        ┌──────────────────┐        ┌─────────────────┐
        │ GracefulShutdown │        │ System.Supervisor
        │ .start_handler   │        │ (rest_for_one)
        └──────────────────┘        └────────┬────────┘
                │                            │
                │                  ┌─────────┴──────────┐
                │                  │                    │
                ▼                  ▼                    ▼
        ┌──────────────┐   ┌──────────────┐   ┌────────────────┐
        │ EventStore   │   │ Deployer     │   │ CapabilityMgr  │
        └──────────────┘   └──────┬───────┘   └────────┬───────┘
                │                 │                    │
                │                 │    ┌───────────────┘
                │                 │    │
                │     ┌───────────┴────┼────────────┐
                │     │                │            │
                ▼     ▼                ▼            ▼
        ┌──────────────────────────────────────────────────┐
        │ Recovery.Replayer (PHASE 9 - NEW)               │
        │ - Reads from EventStore (parent)                │
        │ - Calls Deployer.deploy/1 (sibling)            │
        │ - Queries EventStore for replay data           │
        └──────────────────┬───────────────────────────────┘
                           │
        ┌──────────────────┴──────────────────┐
        │                                     │
        ▼                                     ▼
  ┌──────────────────────┐      ┌──────────────────────┐
  │ TokenStore           │      │ Verifier (PHASE 9)   │
  │ .restore_all_tokens  │      │ .verify_consistency  │
  │ (PHASE 9 - NEW)      │      │ .auto_fix            │
  │                      │      │ (PHASE 9 - NEW)      │
  │ Reads:CubDB tokens   │      │                      │
  │ Writes: ETS table    │      │ Reads: Registry      │
  │                      │      │ Reads: EventStore    │
  │                      │      │ Emits: telemetry     │
  └──────────────────────┘      └──────────────────────┘
```

---

## 10. Crash Recovery vs. Graceful Shutdown

```
SCENARIO 1: CRASH (kill -9)
────────────────────────────

Before Crash:
  EventStore (CubDB)      ← All data on disk ✓
  Vault (CubDB)           ← All data on disk ✓
  TokenStore (CubDB)      ← All data on disk ✓
  Memory (ETS, GenServer) ← All in RAM ✗

CRASH (kill -9 - forced)
  │
  └─ All memory lost ✗
  └─ All disk data intact ✓

Restart:
  EventStore loads from disk       ✓
  TokenStore loads from disk       ✓
  Recovery.Replayer:
    - Reads EventStore events      ✓
    - Redeploys services           ✓
    - TokenStore restores tokens   ✓
  Verifier checks consistency      ✓

Result: COMPLETE RECOVERY


SCENARIO 2: GRACEFUL SHUTDOWN (SIGTERM)
────────────────────────────────────────

Before Shutdown:
  EventStore (CubDB)      ← Data in memory ✓
  Vault (CubDB)           ← Data in memory ✓
  TokenStore (CubDB)      ← Data in memory ✓
  Memory (ETS, GenServer) ← Data in memory ✓

SIGTERM Signal:
  ├─ Emit: :system_shutdown_started
  ├─ Wait 100ms (let pending casts finish)
  ├─ Flush EventStore to disk       ✓
  ├─ Flush TokenStore to disk       ✓
  ├─ Flush Vault to disk            ✓
  ├─ Emit: :system_shutdown_complete
  └─ System.halt(0) - clean exit

After Shutdown:
  All data on disk          ✓
  All CubDB properly closed ✓
  No partial writes         ✓

Restart:
  EventStore loads from disk           ✓
  TokenStore loads from disk           ✓
  Recovery.Replayer:
    - Few/no services to recover
      (since we shut down cleanly)     ✓
  Verifier: all consistent             ✓

Result: FAST STARTUP (< 50ms)


DIFFERENCE:
──────────
Crash:      Slow startup (recovery replay needed)
Shutdown:   Fast startup (minimal recovery needed)
Both:       ZERO DATA LOSS ✓
```

---

## 11. Event Flow: Deploy to Recovery

```
┌───────────────────────────────────────────────────────────┐
│ AGENT REQUESTS: Deploy Service S1                         │
└───────────────────────────┬───────────────────────────────┘
                            │
                            ▼
            ┌───────────────────────────┐
            │ Deployer.deploy/1         │
            │ - Compile code            │
            │ - Start GenServer         │
            │ - Return PID              │
            └───────────┬───────────────┘
                        │
                        ▼
            ┌───────────────────────────┐
            │ Emit Event:               │
            │ :service_deployed         │
            │ - tenant_id: "a1"         │
            │ - service_id: "s1"        │
            │ - code: "defmodule..."    │
            │ - timestamp: now          │
            └───────────┬───────────────┘
                        │
                        ▼
            ┌───────────────────────────┐
            │ EventStore (GenServer)    │
            │ - Append event (cast)     │
            │ - Write to CubDB          │
            │ - :next_id += 1           │
            └───────────┬───────────────┘
                        │
              ┌─────────┴─────────┐
              │                   │
   NOW        │                   │       LATER (after crash)
   ─────────┐ │                   │ ┌──────────────────────
             │ ▼                   │ │
             │ System runs         │ │  CRASH (kill -9)
             │ Service S1 active   │ │
             │ (in memory only)    │ │
             │                     │ ▼
             │                     │ ┌──────────────────────┐
             │                     │ │ Recovery.Replayer    │
             │                     │ │ on startup           │
             │                     │ ├──────────────────────┤
             │                     │ │ 1. Read events       │
             │                     │ │    from EventStore   │
             │                     │ │    (disk) ◄──────────┤──┐
             │                     │ │                      │  │
             │                     │ │ 2. Find event:       │  │
             │                     │ │    :service_deployed │  │
             │                     │ │    tenant: a1        │  │
             │                     │ │    service: s1       │  │
             │                     │ │    code: "..."       │  │
             │                     │ │                      │  │
             │                     │ │ 3. Check for kill:   │  │
             │                     │ │    :service_killed?  │  │
             │                     │ │    NO ✓              │  │
             │                     │ │                      │  │
             │                     │ │ 4. Redeploy:         │  │
             │                     │ │    Deployer.deploy/1 │  │
             │                     │ │    New PID: 456      │  │
             │                     │ │                      │  │
             │                     │ │ 5. Emit event:       │  │
             │                     │ │    :service_recovered│  │
             │                     │ │                      │  │
             │                     │ └──────────────────────┘  │
             │                     │                           │
             │                     │    CubDB (disk)           │
             │                     │    Events stored here ───┘
             └─────────────────────┘
```

---

## 12. Token Lifecycle with Persistence

```
TOKEN LIFECYCLE WITH PERSISTENCE (PHASE 9)

Agent A                  Solo                     ETS              CubDB
  │                       │                       │                 │
  ├─ grant token ────────>│                       │                 │
  │                       │                       │                 │
  │                       ├─ Gen token ───────────>│                 │
  │                       │  "tok_abc"             │                 │
  │                       │                       │                 │
  │                       ├─ Hash & store in ETS ─>│                 │
  │                       │  hash_abc              │                 │
  │                       │                       │                 │
  │                       ├─ Persist to CubDB ─────────────────────>│
  │                       │  {:token, hash_abc}    │  {token,hash}  │
  │                       │  {:tokens_by_tenant}   │  {tokens,a1}   │
  │<─ token ──────────────┤                       │                 │
  │  "tok_abc"            │                       │                 │
  │                       │                       │                 │
  │                       ├─ verify(token) ──────>│                 │
  │                       │  Hash: hash_abc        │                 │
  │<─ VALID ──────────────┤  Found in ETS ✓        │                 │
  │                       │                       │                 │
  │                       │                       │                 │
  │                       ├─ SYSTEM CRASH ────────┼─────────────────┤
  │                       │                       │ LOST            │ SAVED ✓
  │                       │                       │ (ETS empty)     │ (disk)
  │                       │                       │                 │
  │                       ├─ RESTART ────────────────────────────┐  │
  │                       │                       │              │  │
  │                       ├─ TokenStore.restore ──┼──────────────┼─>│
  │                       │  (read from CubDB)    │              │  │
  │                       │                       │<─────────────┼──┤
  │                       ├─ Populate ETS ───────>│ {token,hash} │  │
  │                       │  hash_abc             │ {tokens,a1}  │  │
  │<─ Ready ──────────────┤                       │              │  │
  │  (token restored!)    │                       │              │  │
  │                       │                       │              │  │
  │├─ verify(token) ──────>│                       │              │  │
  │ │ "tok_abc"           │                       │              │  │
  │ │                     ├─ Hash ────────────────>│              │  │
  │ │                     │  hash_abc              │ FOUND ✓      │  │
  │ │<─ VALID ────────────┤                       │              │  │
  │ │                     │                       │              │  │
  │ └─ (Agent can still use token!) ✓             │              │  │
  │                       │                       │              │  │
  ├─ revoke(token) ──────>│                       │              │  │
  │                       ├─ Remove from ETS ────>│ X            │  │
  │                       ├─ Remove from CubDB ─────────────────>│ X
  │<─ REVOKED ────────────┤                       │              │  │
  │                       │                       │              │  │
```

---

This comprehensive architecture documentation shows:
1. System recovery flow on startup
2. Detailed service recovery process
3. Token persistence mechanics
4. Graceful shutdown sequence
5. Consistency verification
6. Data persistence layout on disk
7. Recovery timeline metrics
8. Token storage and restoration
9. Module dependency graph
10. Crash vs. graceful shutdown
11. Complete event flow from deploy to recovery
12. Token lifecycle with persistence

All diagrams illustrate how Phase 9 components work together to provide zero-data-loss persistence.
