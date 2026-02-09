# REST API Implementation Checklist

## Overview
This checklist guides the implementation of the Solo REST API based on the design specification.

---

## Phase 1: Core Service Management (MVP)

### Files to Create
- [x] `lib/solo/gateway/rest/router.ex` - Route definitions
- [x] `lib/solo/gateway/rest/helpers.ex` - Shared utilities
- [x] `lib/solo/gateway/rest/services_handler.ex` - POST/GET /services
- [x] `lib/solo/gateway/rest/service_handler.ex` - GET/DELETE /services/{id}

### Tests to Write
- [ ] Unit tests for helpers module
  - [ ] Tenant extraction from header
  - [ ] Tenant extraction from certificate
  - [ ] JSON encoding/decoding
  - [ ] Query parameter parsing
  - [ ] Service ID validation
  - [ ] Pagination helpers
  
- [ ] Integration tests for handlers
  - [ ] POST /services - successful deploy
  - [ ] POST /services - missing fields
  - [ ] POST /services - invalid service_id
  - [ ] GET /services - list all
  - [ ] GET /services - pagination
  - [ ] GET /services - filtering by status
  - [ ] GET /services/{id} - found
  - [ ] GET /services/{id} - not found
  - [ ] DELETE /services/{id} - success
  - [ ] DELETE /services/{id} - with grace_ms
  - [ ] DELETE /services/{id} - with force
  - [ ] Multi-tenant isolation verification

### Integration Steps
- [ ] Update `lib/solo/gateway.ex` to use REST router
- [ ] Verify HTTP server starts on port 8080
- [ ] Confirm gRPC still works on port 50051
- [ ] Check logs for "[REST]" messages
- [ ] Verify tenant_id extraction works

### Documentation
- [x] Complete API specification (REST_API_DESIGN.md)
- [x] Practical examples (REST_API_EXAMPLES.md)

### Manual Testing
- [ ] Deploy service with curl: `curl -X POST http://localhost:8080/services ...`
- [ ] List services: `curl http://localhost:8080/services ...`
- [ ] Get service status: `curl http://localhost:8080/services/{id} ...`
- [ ] Kill service: `curl -X DELETE http://localhost:8080/services/{id} ...`
- [ ] Test error responses (missing tenant, invalid JSON, etc.)
- [ ] Test tenant isolation (different X-Tenant-ID headers)

---

## Phase 2: Event Streaming

### Files to Create
- [x] `lib/solo/gateway/rest/events_handler.ex` - GET /events (SSE)

### Features
- [x] Server-Sent Events (SSE) streaming
- [x] Query parameter filtering (?service_id)
- [x] Event pagination (?since_id)
- [x] Verbose logging toggle (?include_logs)
- [x] Connection management
- [x] Error handling

### Tests to Write
- [ ] Unit tests
  - [ ] Event encoding to JSON
  - [ ] Event filtering by service_id
  - [ ] Event filtering by event_type
  - [ ] Event stream creation
  
- [ ] Integration tests
  - [ ] SSE connection establishment
  - [ ] Event delivery to client
  - [ ] Event filtering works
  - [ ] Pagination works
  - [ ] Client disconnect handling

### Manual Testing
- [ ] Stream all events: `curl http://localhost:8080/events ...`
- [ ] Stream for service: `curl http://localhost:8080/events?service_id=... ...`
- [ ] Stream from specific ID: `curl http://localhost:8080/events?since_id=1000 ...`
- [ ] Test with JavaScript EventSource API
- [ ] Test client reconnection
- [ ] Monitor memory usage during long streams

### Documentation
- [x] SSE implementation guide in REST_API_DESIGN.md
- [x] JavaScript client example in REST_API_EXAMPLES.md

---

## Phase 3: Production Hardening

### Error Handling
- [ ] Validate all error responses use consistent format
- [ ] Test all HTTP status codes are correct
- [ ] Verify error messages are helpful but not verbose
- [ ] Add request_id tracking (optional)

### Performance
- [ ] Benchmark concurrent requests
- [ ] Test pagination with large datasets
- [ ] Monitor SSE event delivery latency
- [ ] Test under load (concurrent service deployments)

### Logging
- [ ] Verify "[REST]" messages appear in logs
- [ ] Check tenant_id is always logged
- [ ] Ensure sensitive data isn't logged
- [ ] Review log levels (info, warning, error)

### Validation
- [ ] All inputs validated (service_id, JSON, etc.)
- [ ] Query parameters type-checked
- [ ] Request body size limits enforced
- [ ] Service_id format validation consistent

### Security
- [ ] Verify tenant isolation (no cross-tenant access)
- [ ] Test X-Tenant-ID header handling
- [ ] Verify mTLS certificate extraction
- [ ] Check certificate subject parsing

### Documentation
- [ ] API specification complete (REST_API_DESIGN.md)
- [ ] Examples comprehensive (REST_API_EXAMPLES.md)
- [ ] Implementation guide included
- [ ] Troubleshooting section added

### Code Quality
- [ ] Run `mix format` on all files
- [ ] Run `mix credo` and address warnings
- [ ] Run `dialyzer` for type safety
- [ ] Code review by team
- [ ] Update ARCHITECTURE.md with REST API info

---

## Deployment Checklist

### Pre-Deployment
- [ ] All tests passing
- [ ] Code reviewed and approved
- [ ] Documentation complete
- [ ] Examples tested manually
- [ ] Performance benchmarks acceptable

### Deployment Steps
- [ ] Deploy code changes
- [ ] Verify HTTP server starts: `curl http://localhost:8080/health`
- [ ] Verify gRPC server still runs: Test with gRPC client
- [ ] Check logs for errors
- [ ] Run integration tests against live system

### Post-Deployment
- [ ] Monitor logs for "[REST]" messages
- [ ] Check HTTP error rates
- [ ] Verify event streaming latency
- [ ] Monitor system resources (memory, CPU)
- [ ] Get feedback from early users

### Rollback Plan
- [ ] Revert code if issues found
- [ ] gRPC service unaffected (independent)
- [ ] No data loss (read-only operations)

---

## Testing Strategy

### Unit Tests (helpers.ex)
```elixir
# Test tenant extraction
test "extract_tenant_id from header" do
  req = create_mock_request("x-tenant-id", "tenant-1")
  assert {:ok, "tenant-1", _req} = Helpers.extract_tenant_id(req)
end

test "extract_tenant_id from certificate" do
  req = create_mock_request_with_cert("cn=tenant-2")
  assert {:ok, "tenant-2", _req} = Helpers.extract_tenant_id(req)
end
```

### Integration Tests (handlers)
```elixir
# Test service deployment
test "POST /services creates new service" do
  response = post("/services", %{
    "service_id" => "my-service",
    "code" => "...",
    "format" => "elixir_source"
  }, headers: [{"x-tenant-id", "tenant-1"}])
  
  assert response.status == 201
  assert response.body["service_id"] == "my-service"
end

# Test tenant isolation
test "services are isolated by tenant" do
  deploy_service("tenant-1", "service-1")
  deploy_service("tenant-2", "service-1")
  
  # Tenant 1 should only see their service
  services = list_services("tenant-1")
  assert length(services) == 1
  assert services[0]["service_id"] == "service-1"
end
```

### Load Tests
```bash
# Deploy 100 services concurrently
for i in {1..100}; do
  curl -X POST http://localhost:8080/services \
    -H "Content-Type: application/json" \
    -H "X-Tenant-ID: load-test" \
    -d '{"service_id":"service-'$i'","code":"...","format":"elixir_source"}' &
done
wait
```

---

## File Manifest

### Documentation (3 files, ~1600 lines)
```
REST_API_DESIGN.md           - Complete specification
REST_API_EXAMPLES.md         - Practical usage examples
REST_API_SUMMARY.md          - High-level overview
```

### Implementation (6 files, ~850 lines)
```
lib/solo/gateway/rest/router.ex              - Route config (34 lines)
lib/solo/gateway/rest/helpers.ex             - Utilities (288 lines)
lib/solo/gateway/rest/services_handler.ex    - /services (192 lines)
lib/solo/gateway/rest/service_handler.ex     - /services/{id} (177 lines)
lib/solo/gateway/rest/events_handler.ex      - /events (161 lines)
lib/solo/gateway.ex (updated)                - Integration (~80 lines)
```

### Tests (to be written, ~500+ lines)
```
test/solo/gateway/rest/helpers_test.exs
test/solo/gateway/rest/services_handler_test.exs
test/solo/gateway/rest/service_handler_test.exs
test/solo/gateway/rest/events_handler_test.exs
test/solo/gateway/rest/integration_test.exs
```

---

## Quick Start

### 1. Understand Design
- Read: REST_API_DESIGN.md
- Review: REST_API_EXAMPLES.md
- Check: REST_API_SUMMARY.md

### 2. Examine Implementation
- Look at: `lib/solo/gateway/rest/*.ex` files
- Study: Helper functions in `helpers.ex`
- Review: Handler patterns in `*_handler.ex` files

### 3. Set Up Testing
```bash
# Run tests
mix test test/solo/gateway/rest/

# Run specific test
mix test test/solo/gateway/rest/helpers_test.exs:42

# Run with coverage
mix test --cover
```

### 4. Manual Testing
```bash
# Start server
iex -S mix

# In another terminal
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: test" \
  -d '{"service_id":"test-1","code":"defmodule Test do end","format":"elixir_source"}'
```

### 5. Integration
- Update `Solo.Gateway` to use REST router
- Verify both HTTP and gRPC servers start
- Test examples from REST_API_EXAMPLES.md

---

## Success Criteria

- ✅ All 6 endpoints working (POST, GET, DELETE for services; GET for events, health)
- ✅ Proper HTTP status codes (201, 202, 400, 404, 500)
- ✅ Consistent JSON error responses
- ✅ Multi-tenant isolation verified
- ✅ Server-Sent Events streaming working
- ✅ All tests passing
- ✅ No external dependencies added (beyond Jason)
- ✅ Production-ready error handling
- ✅ Comprehensive documentation
- ✅ Examples working with curl and JavaScript

---

## Known Limitations & Future Work

### Current Implementation
- Single-machine deployment (no distributed streaming)
- No rate limiting (can be added)
- No API key authentication (header + cert only)
- No OpenAPI/Swagger auto-generation
- No response caching

### Future Enhancements
- [ ] Rate limiting per tenant
- [ ] API key authentication
- [ ] OpenAPI/Swagger documentation
- [ ] Response caching with ETags
- [ ] Batch operations (deploy multiple services)
- [ ] WebSocket support
- [ ] Graphical API browser
- [ ] Request tracing with X-Request-ID
- [ ] Custom headers for observability

---

## Support & Troubleshooting

### Common Issues

**HTTP server won't start**
- Check port 8080 not in use: `netstat -tuln | grep 8080`
- Verify Cowboy dependency available
- Check logs for startup errors

**No services showing**
- Verify X-Tenant-ID header sent
- Check service actually deployed (check gRPC)
- Look for "[REST]" messages in logs

**Events not streaming**
- Verify EventStore has events
- Check SSE headers set correctly
- Test with `curl -v` to see headers
- Check for errors in logs

**Tenant isolation failing**
- Verify different X-Tenant-ID headers used
- Check tenant extraction logic
- Review logs for tenant_id values

---

## Contact & Discussion

For questions about implementation:
1. Review REST_API_DESIGN.md specification
2. Check REST_API_EXAMPLES.md for usage patterns
3. Examine handler code and comments
4. Review test cases

For feature requests:
- Document in REST_API_DESIGN.md "Future Enhancements"
- Create GitHub issue with details
- Discuss with team

For bugs:
- Provide curl command to reproduce
- Include request and response
- Note Solo version and OS
- Check logs for error messages
