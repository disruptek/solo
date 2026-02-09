# Phase 9: Task Checklist & Sprint Planning

## Overview
- **Total Tasks:** 47 items across 4 components + testing + documentation
- **Estimated Duration:** 15-21 working days
- **Dependencies:** None (can start immediately after v0.2.0)
- **Test Coverage Goal:** 40+ new tests for Phase 9

---

## Component 1: Event Replay Recovery (Days 1-3)

### Task 1.1: Create Replayer Module Structure
- [ ] Create file: `lib/solo/recovery/replayer.ex`
- [ ] Define module with docstring
- [ ] Define public API:
  - [ ] `start_link/1` - supervisor integration
  - [ ] `replay_deployments/0` - main replay function
  - [ ] `verify_recovery/0` - consistency check
  - [ ] `recovery_report/0` - get last recovery status
- [ ] Implement as GenServer (temporary restart)

### Task 1.2: Implement Deployment Replay Logic
- [ ] Query EventStore for all `:service_deployed` events
- [ ] Group events by `{tenant_id, service_id}`
- [ ] For each group, find latest deployment
- [ ] Check for corresponding `:service_killed` event
- [ ] Build recovery plan (which services to redeploy)
- [ ] Return: `{:ok, %{count: N, services: [...]}}` or `{:error, reason}`

### Task 1.3: Implement Service Redeployment
- [ ] Extract deployment spec from `:service_deployed` event payload
- [ ] Call `Solo.Deployment.Deployer.deploy/1` with original spec
- [ ] Handle redeployment errors gracefully
- [ ] Log each redeployment with telemetry
- [ ] Track successful vs failed recoveries
- [ ] Return recovery statistics

### Task 1.4: Integration with Deployer
- [ ] Modify `Solo.Deployment.Deployer.init/1`
- [ ] Call recovery after deployer is initialized
- [ ] Handle recovery failures without blocking startup
- [ ] Add startup logging
- [ ] Ensure recovery is idempotent (safe to run multiple times)

### Task 1.5: Integration with Supervisor
- [ ] Update `Solo.System.Supervisor.init/1`
- [ ] Add `Solo.Recovery.Replayer` to children list
- [ ] Configure as `restart: :temporary` (one-shot)
- [ ] Ensure correct startup order (after EventStore, Deployer)

### Task 1.6: Test Event Replay
- [ ] Create file: `test/solo/recovery/replayer_test.exs`
- [ ] Test 1: Single service recovery
  - [ ] Deploy service, emit event, replay, verify recovered
- [ ] Test 2: Multiple services recovery
  - [ ] Deploy 5 services, replay, all recover
- [ ] Test 3: Service killed before recovery
  - [ ] Deploy, kill, emit :service_killed, replay, should NOT recover
- [ ] Test 4: Partial recovery (some deployments fail)
  - [ ] Replay with missing code (compile error), continue
- [ ] Test 5: Multiple tenants
  - [ ] Deploy across 3 tenants, replay all, verify isolation
- [ ] Test 6: Large event log (1000 events)
  - [ ] Performance test, should complete < 10 seconds
- [ ] Test 7: No events to replay
  - [ ] Empty system, replay does nothing, returns {:ok, %{count: 0}}
- [ ] Test 8: Idempotency
  - [ ] Replay twice, same result both times

---

## Component 2: Capability Token Persistence (Days 4-6)

### Task 2.1: Create TokenStore Module
- [ ] Create file: `lib/solo/capability/token_store.ex`
- [ ] Define module with docstring
- [ ] Define public API:
  - [ ] `start_link/1` - supervisor integration (simple GenServer)
  - [ ] `store_token/3` - persist token (token_hash, capability, metadata)
  - [ ] `restore_all_tokens/1` - restore to ETS table on startup
  - [ ] `revoke_token/1` - remove from persistence
  - [ ] `token_exists?/1` - check if token persisted
  - [ ] `cleanup_expired/0` - remove expired tokens

### Task 2.2: Define Token Data Structure
- [ ] Define token record in CubDB:
  ```elixir
  %{
    token_hash: "abc123...",
    permission: :deploy,
    tenant_id: "agent_1",
    granted_at: DateTime.t(),
    expires_at: DateTime.t() | nil,
    metadata: map()
  }
  ```
- [ ] Create validation function for token structure
- [ ] Add type specs for all functions

### Task 2.3: Implement Token Storage
- [ ] Implement `store_token/3`:
  - [ ] Validate inputs
  - [ ] Write to CubDB: `{:token, token_hash}` → token map
  - [ ] Maintain index: `{:tokens_by_tenant, tenant_id}` → set of token_hashes
  - [ ] Return `:ok` or `{:error, reason}`
- [ ] Add error handling for CubDB failures
- [ ] Log all token storage operations

### Task 2.4: Implement Token Restoration
- [ ] Implement `restore_all_tokens/1`:
  - [ ] Accept ETS table as parameter
  - [ ] Query all tokens from CubDB
  - [ ] Filter out expired tokens
  - [ ] Insert non-expired tokens into ETS
  - [ ] Return count restored
- [ ] Handle missing CubDB gracefully
- [ ] Handle corrupted token records (skip with warning)

### Task 2.5: Integration with Capability Manager
- [ ] Modify `Solo.Capability.Manager.init/1`:
  - [ ] After creating ETS table, call `TokenStore.restore_all_tokens`
  - [ ] Log count of restored tokens
  - [ ] Handle restoration failures
- [ ] Modify `Solo.Capability.Manager.grant/3`:
  - [ ] After storing token in ETS, call `TokenStore.store_token`
  - [ ] Handle persistence failures gracefully
  - [ ] Log if persistence fails (don't fail grant)
- [ ] Modify `Solo.Capability.Manager.revoke/1`:
  - [ ] Call `TokenStore.revoke_token` in addition to ETS removal
  - [ ] Handle revocation failures
- [ ] Add telemetry events:
  - [ ] `:capability, :token_persisted`
  - [ ] `:capability, :token_restored`

### Task 2.6: Implement Token Cleanup
- [ ] Implement `cleanup_expired/0`:
  - [ ] Query all tokens from CubDB
  - [ ] Find expired tokens (expires_at < now)
  - [ ] Remove from CubDB and indexes
  - [ ] Return count cleaned up
- [ ] Schedule cleanup (hourly, configurable)
- [ ] Add cleanup counter for monitoring

### Task 2.7: Test Token Persistence
- [ ] Create file: `test/solo/capability/token_store_test.exs`
- [ ] Test 1: Store and retrieve token
  - [ ] Store token, read from CubDB, verify structure
- [ ] Test 2: Restore tokens on startup
  - [ ] Store token, simulate restart, verify restored to ETS
- [ ] Test 3: Ignore expired tokens
  - [ ] Store expired token, restore, should not be in ETS
- [ ] Test 4: Revoke token
  - [ ] Store token, revoke, verify removed from CubDB and ETS
- [ ] Test 5: Multiple tenants
  - [ ] Store tokens for 3 tenants, restore all, verify isolation
- [ ] Test 6: Index maintenance
  - [ ] Store tokens, verify {tokens_by_tenant, tenant_id} index correct
- [ ] Test 7: Large number of tokens
  - [ ] Store 1000 tokens, restore, performance < 5 seconds
- [ ] Test 8: Cleanup expired
  - [ ] Store mix of expired/non-expired, cleanup, verify correct removal
- [ ] Test 9: Corruption handling
  - [ ] Insert malformed token, restore, should skip with warning

---

## Component 3: Graceful Shutdown (Days 7-8)

### Task 3.1: Create Graceful Shutdown Module
- [ ] Create file: `lib/solo/shutdown/graceful_shutdown.ex`
- [ ] Define module with docstring
- [ ] Define public API:
  - [ ] `start_handler/0` - register signal handler
  - [ ] `shutdown_sequence/0` - execute shutdown
  - [ ] `shutdown_in_progress?/0` - check status
- [ ] Implement as utility module (not GenServer)

### Task 3.2: Implement Signal Handler
- [ ] Check Elixir version for `System.trap_signal/2` availability
- [ ] If Elixir 1.15+: use `System.trap_signal(:sigterm, ...)`
- [ ] If Elixir < 1.15: use `:erl_signal_server` or direct Erlang
- [ ] Register handler in `Solo.Kernel.start/2`
- [ ] Handler should:
  - [ ] Emit `:system_shutdown_started` event
  - [ ] Call `shutdown_sequence/0`
  - [ ] Exit with code 0 on success
  - [ ] Exit with code 1 on failure

### Task 3.3: Implement Shutdown Sequence
- [ ] Implement `shutdown_sequence/0`:
  1. [ ] Emit `:system_shutdown_started` event
  2. [ ] Log "Graceful shutdown initiated"
  3. [ ] Wait 100ms for pending GenServer.cast operations
  4. [ ] Call EventStore flush (if method exists, else skip)
  5. [ ] Call Vault flush (if method exists, else skip)
  6. [ ] Call TokenStore flush (if method exists, else skip)
  7. [ ] Emit `:system_shutdown_complete` event
  8. [ ] Log "Graceful shutdown complete"
  9. [ ] Call `System.halt(0)` for clean exit

### Task 3.4: Add EventStore Flush Method
- [ ] Add `Solo.EventStore.flush/0` function:
  - [ ] Ensure all pending casts are processed
  - [ ] Flush CubDB to disk
  - [ ] Return `:ok` or `{:error, reason}`

### Task 3.5: Add Vault Flush Method
- [ ] Add `Solo.Vault.flush/0` function (if not exists):
  - [ ] Ensure CubDB is flushed
  - [ ] Return `:ok`

### Task 3.6: Integration with Kernel
- [ ] Modify `Solo.Kernel.start/2`:
  - [ ] Call `Solo.Shutdown.GracefulShutdown.start_handler/0` during startup
  - [ ] Handle handler registration failures gracefully
  - [ ] Log handler registration

### Task 3.7: Test Graceful Shutdown
- [ ] Create file: `test/solo/shutdown/graceful_shutdown_test.exs`
- [ ] Test 1: Signal handler registered
  - [ ] Verify handler exists and is functional
- [ ] Test 2: Shutdown sequence completes
  - [ ] Simulate shutdown, verify sequence executes
- [ ] Test 3: Events emitted
  - [ ] Verify :system_shutdown_started and :system_shutdown_complete events
- [ ] Test 4: CubDB flushed
  - [ ] Verify flush methods called
- [ ] Test 5: Exit code correct
  - [ ] Verify exit code 0 on success, 1 on failure
- [ ] Test 6: Timeout handling
  - [ ] Verify shutdown completes even if flush times out

---

## Component 4: State Verification (Days 9-10)

### Task 4.1: Create Verifier Module
- [ ] Create file: `lib/solo/recovery/verifier.ex`
- [ ] Define module with docstring
- [ ] Define public API:
  - [ ] `verify_consistency/0` - run verification
  - [ ] `verification_report/0` - get last report
  - [ ] `auto_fix/0` - attempt to fix inconsistencies

### Task 4.2: Implement Consistency Verification
- [ ] Implement `verify_consistency/0`:
  - [ ] Get all deployed services from Registry
  - [ ] Get all `:service_deployed` events from EventStore
  - [ ] Get all `:service_killed` events
  - [ ] Check invariants:
    - [ ] Every deployed service has :service_deployed event
    - [ ] No deployed service has :service_killed after last :service_deployed
    - [ ] Every :service_deployed event without :service_killed has corresponding service
    - [ ] Service counts match expected values
  - [ ] Return: `{:ok, report}` or `{:error, inconsistencies}`

### Task 4.3: Generate Verification Report
- [ ] Define report structure:
  ```elixir
  %{
    timestamp: DateTime.t(),
    status: :ok | :warning | :error,
    consistency_checks: %{
      services_deployed: count,
      services_recovered: count,
      services_killed: count,
      inconsistencies: []
    },
    recommendations: []
  }
  ```
- [ ] Implement report generation
- [ ] Add logging for each check

### Task 4.4: Implement Auto-Fix Logic
- [ ] Implement `auto_fix/0`:
  - [ ] Scan for inconsistencies
  - [ ] For orphaned services (no event): emit :service_deployed event
  - [ ] For orphaned events (no service): expect :service_killed event
  - [ ] For both missing: log as error (don't fix)
  - [ ] Return: `{:ok, fixes}` or `{:error, reason}`

### Task 4.5: Integration with Replayer
- [ ] Call `verify_consistency/0` after replay completes
- [ ] If inconsistencies found:
  - [ ] Log warning with details
  - [ ] Emit telemetry event
  - [ ] Attempt auto-fix if enabled
  - [ ] Continue (don't fail startup)

### Task 4.6: Test Verification
- [ ] Create file: `test/solo/recovery/verifier_test.exs`
- [ ] Test 1: Perfect consistency
  - [ ] Deploy 5 services, verify all checks pass
- [ ] Test 2: Orphaned service
  - [ ] Manually insert service without event, verify detected
- [ ] Test 3: Orphaned event
  - [ ] Emit event but don't deploy, verify detected
- [ ] Test 4: Service killed
  - [ ] Deploy, kill, verify killed event detected
- [ ] Test 5: Auto-fix orphaned event
  - [ ] Emit event without service, auto-fix, verify event creation works
- [ ] Test 6: Count verification
  - [ ] Deploy multiple services, verify counts match
- [ ] Test 7: Report generation
  - [ ] Verify report structure and content

---

## Integration Testing (Days 11-13)

### Task 5.1: Full Recovery Cycle Tests
- [ ] Create file: `test/solo/integration/recovery_cycle_test.exs`
- [ ] Test: Deploy → List → Crash → Recover → Verify
  - [ ] Deploy 3 services to tenant A
  - [ ] Verify services running
  - [ ] Simulate system crash (stop application)
  - [ ] Start application again
  - [ ] Verify all 3 services recovered
  - [ ] Verify service states identical
- [ ] Test: Multiple Tenants
  - [ ] Deploy to 5 tenants (5 services each)
  - [ ] Crash, recover, verify all recovered with isolation
- [ ] Test: Tokens Across Restart
  - [ ] Grant 10 capability tokens
  - [ ] Crash system
  - [ ] Restart
  - [ ] Verify all 10 tokens still valid
  - [ ] Verify token verification still works
- [ ] Test: Service Kill + Recovery
  - [ ] Deploy 2 services
  - [ ] Kill one service
  - [ ] Emit :service_killed event
  - [ ] Crash
  - [ ] Recover
  - [ ] Verify only 1 service recovered
- [ ] Test: Graceful Shutdown
  - [ ] Deploy services
  - [ ] Send SIGTERM
  - [ ] Verify graceful shutdown
  - [ ] Verify no data loss
  - [ ] Restart and verify recovery

### Task 5.2: Stress Tests
- [ ] Create file: `test/solo/integration/stress_recovery_test.exs`
- [ ] Test: Large Event Log (1000 events)
  - [ ] Generate 1000 events
  - [ ] Recovery should complete < 10 seconds
  - [ ] Verify memory usage reasonable
- [ ] Test: Many Tokens (10000)
  - [ ] Grant 10000 tokens
  - [ ] Recovery should complete < 5 seconds
  - [ ] Verify all tokens restored
- [ ] Test: Long Running System (72+ hours)
  - [ ] Deploy/kill/recover cycles
  - [ ] Periodic verification
  - [ ] Monitor for leaks
  - [ ] (Skip in CI, run locally)
- [ ] Test: Rapid Restarts
  - [ ] Deploy, crash, restart 10 times quickly
  - [ ] Verify consistency maintained

### Task 5.3: Edge Case Tests
- [ ] Create file: `test/solo/integration/recovery_edge_cases_test.exs`
- [ ] Test: Corrupted Event
  - [ ] Insert malformed event, recovery should skip with warning
- [ ] Test: Missing Service Code
  - [ ] Emit event with code that won't compile
  - [ ] Recovery should skip that service
  - [ ] Emit :service_recovery_failed event
- [ ] Test: Concurrent Deploy During Recovery
  - [ ] Start recovery, deploy new service during recovery
  - [ ] Both should complete successfully
- [ ] Test: Event Log Gap
  - [ ] Delete an event from EventStore, recovery continues
- [ ] Test: Token Persistence Failure
  - [ ] If TokenStore fails, token grant should still work (warning logged)

---

## Documentation (Days 14-15)

### Task 6.1: Update README.md
- [ ] Add section: "Persistence & Recovery (Phase 9)"
- [ ] Update "Known Limitation" section to show Phase 9 complete
- [ ] Add recovery guarantees
- [ ] Update Architecture section with recovery flow
- [ ] Update test coverage count (163 → 200+)

### Task 6.2: Create Operational Guide
- [ ] Create file: `docs/OPERATIONS_GUIDE.md`
- [ ] Section 1: Recovery Process
  - [ ] How recovery works
  - [ ] What happens on startup
  - [ ] How to verify recovery
- [ ] Section 2: Graceful Shutdown
  - [ ] How to shutdown safely
  - [ ] SIGTERM handling
  - [ ] Data consistency
- [ ] Section 3: Troubleshooting
  - [ ] Common recovery issues
  - [ ] How to debug
  - [ ] Manual recovery steps
- [ ] Section 4: Monitoring Recovery
  - [ ] Telemetry events
  - [ ] Logs to watch
  - [ ] Alerts to set

### Task 6.3: Create Recovery Troubleshooting Guide
- [ ] Create file: `docs/RECOVERY_TROUBLESHOOTING.md`
- [ ] Common Issues:
  - [ ] "Services not recovered after restart"
  - [ ] "Token not valid after restart"
  - [ ] "Inconsistency detected in recovery"
  - [ ] "Recovery taking too long"
- [ ] For each issue:
  - [ ] Symptoms
  - [ ] Root causes
  - [ ] Solutions
  - [ ] Logs to check

### Task 6.4: Update API Documentation
- [ ] Update `docs/OTP_API.md`:
  - [ ] Add Recovery module API
  - [ ] Add TokenStore API
  - [ ] Add GracefulShutdown API
  - [ ] Add Verifier API
- [ ] Add examples for each function
- [ ] Document error cases

### Task 6.5: Update ROADMAP.md
- [ ] Update Phase 9 status from CRITICAL to ✅ COMPLETE
- [ ] Add completion date
- [ ] Update v0.3.0 status
- [ ] Link to recovery guide

---

## Code Quality & Standards (Days 16-17)

### Task 7.1: Code Review & Style
- [ ] Run `mix format` on all new files
- [ ] Check Credo warnings: `mix credo`
- [ ] Review all module docstrings
- [ ] Review all function docstrings
- [ ] Check type specs (@spec)

### Task 7.2: Test Coverage
- [ ] Run `mix test --cover`
- [ ] Verify Phase 9 code > 90% covered
- [ ] Identify and cover untested paths
- [ ] Add doctests for examples in docstrings

### Task 7.3: Performance Profiling
- [ ] Profile recovery with 1000 events
- [ ] Profile token restoration
- [ ] Identify bottlenecks
- [ ] Optimize hot paths
- [ ] Document performance characteristics

### Task 7.4: Security Review
- [ ] Review token persistence security
- [ ] Verify no secrets in logs
- [ ] Check error messages (no leaks)
- [ ] Review signal handler safety
- [ ] Verify crash recovery safety

---

## Verification & Acceptance (Days 18-21)

### Task 8.1: Full Test Suite
- [ ] Run all tests: `mix test`
  - [ ] Verify 163+ existing tests still pass
  - [ ] Verify 40+ new Phase 9 tests pass
  - [ ] Total: 200+ tests passing
- [ ] Run with different random seeds
- [ ] Run with coverage

### Task 8.2: Manual Integration Testing
- [ ] Deploy service manually
- [ ] Verify it runs
- [ ] Kill system process (kill -TERM)
- [ ] Start system
- [ ] Verify service recovered
- [ ] Test with multiple tenants
- [ ] Test with many services (100+)

### Task 8.3: Documentation Review
- [ ] Read all new documentation
- [ ] Verify all examples work
- [ ] Verify no broken links
- [ ] Check consistency with code
- [ ] Peer review

### Task 8.4: Release Preparation
- [ ] Update version in `mix.exs` to v0.3.0
- [ ] Create CHANGELOG entry
- [ ] Tag version in git
- [ ] Draft release notes
- [ ] Verify CI passes

---

## Summary by Phase

| Phase | Component | Days | Tests | Status |
|-------|-----------|------|-------|--------|
| 1 | Event Replay | 3 | 8 | Foundation |
| 2 | Token Persistence | 3 | 9 | Integration |
| 3 | Graceful Shutdown | 2 | 6 | Cleanup |
| 4 | Verification | 2 | 7 | Polish |
| 5 | Integration Testing | 3 | 15 | Validation |
| 6 | Documentation | 2 | - | Communication |
| 7 | Code Quality | 2 | - | Standards |
| 8 | Acceptance | 3 | - | Release |
| **TOTAL** | **8 Components** | **21 days** | **45+ tests** | **v0.3.0** |

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Recovery takes too long | Set timeout, implement checkpointing (Phase 10) |
| Token persistence fails | Log warning, continue with expired tokens, retry later |
| Signal handler doesn't work | Test signal handling explicitly, fallback to crash recovery |
| Event log corrupted | Add EventStore checksum validation, implement backup |
| Concurrent recovery issues | Add locking, sequencing, ensure idempotency |
| Integration complexity | Use integration tests heavily, test real scenarios |

---

## Dependencies

### Code Dependencies (None - internal only)
- Uses existing Solo modules
- Uses existing CubDB
- No external library additions

### Knowledge Dependencies
- Elixir GenServer patterns
- CubDB API
- Erlang signal handling
- OTP supervision

### External Dependencies
- None

---

## How to Use This Checklist

1. **Print or reference** this checklist during implementation
2. **Check off items** as they're completed
3. **Update status** in git commits (e.g., "Task 1.2: Implement Deployment Replay")
4. **Run tests** before checking off
5. **Commit frequently** with clear messages

Example commit:
```
git commit -m "Task 1.1: Create Replayer module structure with tests"
```

---

## Next Steps (After Phase 9)

Once all tasks complete and tests pass:

1. **Merge** Phase 9 implementation
2. **Tag** v0.3.0 release
3. **Start Phase 10:** Performance optimization (checkpointing, benchmarks)
4. **Celebrate** - Solo now has persistent services!

---

Status: **Ready for implementation**
