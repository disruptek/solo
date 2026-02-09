# Solo REST API Design Specification

## Overview

This document defines a complementary REST API for the Solo gateway that provides HTTP/JSON alternatives to the existing gRPC interface. The REST API is built on top of the same underlying service management infrastructure, providing a more accessible interface for HTTP-based clients while maintaining feature parity with gRPC.

**Server**: HTTP on port 8080 (alongside existing gRPC on 50051)
**Protocol**: REST + JSON
**Content-Type**: `application/json`
**Response Format**: JSON objects with consistent error handling

---

## Authentication & Tenant Identification

### Approach: Header-Based with Optional mTLS

Tenants can be identified via:

1. **Primary**: `X-Tenant-ID` header (for HTTP clients)
   ```
   GET /services HTTP/1.1
   X-Tenant-ID: acme-corp
   ```

2. **Secondary**: mTLS Client Certificate CN/SAN field
   - Client certificate CommonName is extracted as tenant_id
   - Falls back if header not provided

3. **Error Handling**:
   - Missing tenant ID → 400 Bad Request
   - Invalid tenant ID format → 400 Bad Request
   - Unauthorized → 403 Forbidden

### Implementation

```elixir
def extract_tenant_id(req) do
  # Try header first
  case :cowboy_req.header("x-tenant-id", req) do
    {tenant_id, _req} when is_binary(tenant_id) and byte_size(tenant_id) > 0 ->
      {:ok, tenant_id, req}
    _ ->
      # Fallback to mTLS certificate
      extract_tenant_from_cert(req)
  end
end

defp extract_tenant_from_cert(req) do
  case :cowboy_req.cert(req) do
    undefined ->
      {:error, "Missing tenant identification"}
    cert ->
      # Extract CN from certificate
      case parse_cert_subject(cert) do
        {:ok, tenant_id} -> {:ok, tenant_id, req}
        :error -> {:error, "Invalid certificate"}
      end
  end
end
```

---

## REST Endpoints Specification

### 1. Service Management Endpoints

#### 1.1 Deploy Service
```
POST /services
Content-Type: application/json
X-Tenant-ID: acme-corp

Request Body:
{
  "service_id": "my-agent-v1",
  "code": "defmodule MyAgent do ... end",
  "format": "elixir_source"
}

Response (201 Created):
{
  "service_id": "my-agent-v1",
  "status": "deployed",
  "message": "Service deployed successfully",
  "timestamp": "2026-02-09T12:34:56Z"
}

Error Response (400 Bad Request):
{
  "error": "invalid_request",
  "message": "Service code compilation failed",
  "details": "Line 5: unexpected token",
  "timestamp": "2026-02-09T12:34:56Z"
}

Error Response (409 Conflict):
{
  "error": "service_exists",
  "message": "Service 'my-agent-v1' already deployed",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

#### 1.2 List Services
```
GET /services
X-Tenant-ID: acme-corp

Query Parameters (optional):
  ?status=running     Filter by status (running, stopped, crashed, etc.)
  ?limit=50          Pagination limit (default: 100, max: 1000)
  ?offset=0          Pagination offset (default: 0)

Response (200 OK):
{
  "services": [
    {
      "service_id": "my-agent-v1",
      "status": "running",
      "alive": true,
      "created_at": "2026-02-09T10:00:00Z",
      "metadata": {
        "memory_bytes": 1048576,
        "message_queue_len": 0,
        "reductions": 50000
      }
    },
    {
      "service_id": "my-agent-v2",
      "status": "crashed",
      "alive": false,
      "created_at": "2026-02-09T11:00:00Z",
      "crashed_at": "2026-02-09T11:30:00Z",
      "crash_reason": "resource_limit_exceeded",
      "metadata": {}
    }
  ],
  "total": 2,
  "limit": 50,
  "offset": 0,
  "timestamp": "2026-02-09T12:34:56Z"
}

Error Response (400 Bad Request):
{
  "error": "missing_tenant_id",
  "message": "X-Tenant-ID header required",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

#### 1.3 Get Service Status
```
GET /services/{service_id}
X-Tenant-ID: acme-corp

Response (200 OK):
{
  "service_id": "my-agent-v1",
  "status": "running",
  "alive": true,
  "created_at": "2026-02-09T10:00:00Z",
  "updated_at": "2026-02-09T12:30:00Z",
  "metadata": {
    "memory_bytes": 1048576,
    "message_queue_len": 5,
    "reductions": 500000
  },
  "recent_events": [
    {
      "id": 1001,
      "event_type": "service_started",
      "timestamp": "2026-02-09T10:00:00Z",
      "payload": {}
    },
    {
      "id": 1002,
      "event_type": "atom_usage_high",
      "timestamp": "2026-02-09T12:30:00Z",
      "payload": { "usage": 98500 }
    }
  ],
  "timestamp": "2026-02-09T12:34:56Z"
}

Error Response (404 Not Found):
{
  "error": "not_found",
  "message": "Service 'my-agent-v1' not found",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

#### 1.4 Delete Service
```
DELETE /services/{service_id}
X-Tenant-ID: acme-corp

Query Parameters (optional):
  ?force=false       Force kill without grace period (default: false)
  ?grace_ms=5000     Grace period in milliseconds (default: 5000)

Response (202 Accepted):
{
  "service_id": "my-agent-v1",
  "status": "terminating",
  "message": "Service termination initiated",
  "grace_period_ms": 5000,
  "timestamp": "2026-02-09T12:34:56Z"
}

Error Response (404 Not Found):
{
  "error": "not_found",
  "message": "Service 'my-agent-v1' not found",
  "timestamp": "2026-02-09T12:34:56Z"
}

Error Response (409 Conflict):
{
  "error": "already_terminating",
  "message": "Service is already terminating",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

### 2. Monitoring & Events Endpoints

#### 2.1 Get Health Status
```
GET /health
(No authentication required - system-level health)

Response (200 OK):
{
  "status": "healthy",
  "timestamp": "2026-02-09T12:34:56Z",
  "components": {
    "event_store": "ok",
    "registry": "ok",
    "deployer": "ok",
    "gateway": "ok"
  },
  "metrics": {
    "total_services": 42,
    "active_services": 38,
    "total_events": 15234,
    "atom_count": 12500,
    "memory_used_mb": 256
  }
}

Response (503 Service Unavailable):
{
  "status": "unhealthy",
  "timestamp": "2026-02-09T12:34:56Z",
  "components": {
    "event_store": "down",
    "registry": "ok",
    "deployer": "ok",
    "gateway": "ok"
  },
  "error": "Event store unavailable"
}
```

#### 2.2 Stream Events (Server-Sent Events)
```
GET /events
X-Tenant-ID: acme-corp

Query Parameters (optional):
  ?service_id=my-agent-v1    Filter by service (optional)
  ?since_id=1000             Stream events after ID 1000 (default: 0)
  ?include_logs=false        Include verbose logging events (default: false)

Response Header (200 OK):
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

Response Stream (Server-Sent Events format):
data: {"id":1001,"event_type":"service_started","timestamp":"2026-02-09T10:00:00Z","service_id":"my-agent-v1","payload":{}}

data: {"id":1002,"event_type":"atom_usage_high","timestamp":"2026-02-09T10:00:05Z","service_id":"my-agent-v1","payload":{"usage":98000}}

data: {"id":1003,"event_type":"service_message_sent","timestamp":"2026-02-09T10:00:10Z","service_id":"my-agent-v1","payload":{"message":"request processed","queue_len":0}}

Reconnection:
- SSE automatically reconnects on connection loss
- Client should track last_id and use ?since_id query parameter
- No polling needed - push-based event delivery
```

---

## Error Response Format

All error responses follow a consistent structure:

```json
{
  "error": "error_code",           // Machine-readable error identifier
  "message": "User-friendly message", // Helpful error description
  "details": "Additional context",  // Optional: more detailed info
  "timestamp": "2026-02-09T12:34:56Z", // ISO 8601 timestamp
  "request_id": "req-abc123..."   // Optional: for tracing
}
```

### Standard HTTP Status Codes

| Status | Meaning | Example |
|--------|---------|---------|
| 200 | OK | Service status retrieved |
| 201 | Created | Service deployed successfully |
| 202 | Accepted | Service kill initiated |
| 400 | Bad Request | Missing tenant ID, invalid JSON |
| 401 | Unauthorized | (Reserved for future auth) |
| 403 | Forbidden | Tenant cannot access resource |
| 404 | Not Found | Service doesn't exist |
| 409 | Conflict | Service already exists |
| 500 | Internal Server Error | Unexpected failure |
| 503 | Service Unavailable | Gateway/system unavailable |

---

## Implementation Architecture

### 1. Handler Structure (Cowboy)

Each endpoint is implemented as a Cowboy HTTP handler module:

```
lib/solo/gateway/
├── rest/
│   ├── services_handler.ex          (POST, GET /services)
│   ├── service_handler.ex           (GET, DELETE /services/{id})
│   ├── events_handler.ex            (GET /events - SSE)
│   └── health_handler.ex            (GET /health - existing)
├── middleware/
│   ├── tenant_extractor.ex          (Extract tenant from header/cert)
│   ├── json_decoder.ex              (Parse JSON requests)
│   └── json_encoder.ex              (Encode JSON responses)
└── router.ex                        (Route configuration)
```

### 2. Router Implementation

```elixir
defmodule Solo.Gateway.Router do
  def routes do
    :cowboy_router.compile([
      {:_,
       [
         # Services endpoints
         {"POST", "/services", Solo.Gateway.REST.ServicesHandler, [action: :create]},
         {"GET", "/services", Solo.Gateway.REST.ServicesHandler, [action: :list]},
         {"GET", "/services/:service_id", Solo.Gateway.REST.ServiceHandler, [action: :show]},
         {"DELETE", "/services/:service_id", Solo.Gateway.REST.ServiceHandler, [action: :delete]},
         
         # Events endpoint (SSE)
         {"GET", "/events", Solo.Gateway.REST.EventsHandler, []},
         
         # Health endpoint
         {"GET", "/health", Solo.Gateway.HealthHandler, []},
         
         # 404
         {"_", "/:_", Solo.Gateway.NotFoundHandler, []}
       ]}
    ])
  end
end
```

### 3. Handler Pattern

```elixir
defmodule Solo.Gateway.REST.ServicesHandler do
  require Logger
  
  def init(req, state) do
    {:cowboy_rest, req, state}
  end
  
  # Allowed methods
  def allowed_methods(req, state) do
    {["GET", "POST"], req, state}
  end
  
  # Content negotiation
  def content_types_provided(req, state) do
    {[{"application/json", :to_json}], req, state}
  end
  
  def content_types_accepted(req, state) do
    {[{"application/json", :from_json}], req, state}
  end
  
  # POST /services - Deploy service
  def from_json(req, state) do
    with {:ok, tenant_id, req} <- extract_tenant(req),
         {:ok, body, req} <- read_body(req),
         {:ok, params} <- decode_json(body),
         {:ok, pid} <- deploy_service(tenant_id, params) do
      response = %{
        service_id: params["service_id"],
        status: "deployed",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      req = :cowboy_req.set_resp_header("content-type", "application/json", req)
      req = :cowboy_req.reply(201, %{}, Jason.encode!(response), req)
      {true, req, state}
    else
      {:error, reason} -> error_response(req, state, reason)
    end
  end
  
  # GET /services - List services
  def to_json(req, state) do
    with {:ok, tenant_id, req} <- extract_tenant(req),
         services <- list_services(tenant_id) do
      response = %{
        services: services,
        total: length(services),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      {Jason.encode!(response), req, state}
    else
      {:error, reason} -> error_response(req, state, reason)
    end
  end
end
```

### 4. Middleware for Tenant Extraction

```elixir
defmodule Solo.Gateway.Middleware.TenantExtractor do
  @moduledoc """
  Cowboy middleware to extract tenant_id from X-Tenant-ID header
  or mTLS certificate and make it available to handlers.
  """
  
  def execute(req, env) do
    case extract_tenant_id(req) do
      {:ok, tenant_id} ->
        # Store in req metadata
        {:ok, req, Map.put(env, :tenant_id, tenant_id)}
      
      {:error, reason} ->
        # Return 400 error
        body = Jason.encode!(%{
          error: "missing_tenant_id",
          message: reason
        })
        req = :cowboy_req.reply(400, %{"content-type" => "application/json"}, body, req)
        {:stop, req}
    end
  end
  
  defp extract_tenant_id(req) do
    # Try header first
    case :cowboy_req.header("x-tenant-id", req) do
      {tenant_id, _} when is_binary(tenant_id) and byte_size(tenant_id) > 0 ->
        {:ok, tenant_id}
      _ ->
        # Try mTLS certificate
        extract_from_cert(req)
    end
  end
end
```

### 5. Server-Sent Events Implementation

```elixir
defmodule Solo.Gateway.REST.EventsHandler do
  @moduledoc """
  Server-Sent Events (SSE) endpoint for real-time event streaming.
  Provides push-based event delivery to HTTP clients.
  """
  
  def init(req, state) do
    {:cowboy_loop, req, state}
  end
  
  def handle(req, state) do
    # Extract parameters
    {:ok, tenant_id, req} = extract_tenant(req)
    service_id = :cowboy_req.qs_val("service_id", req, "")
    since_id = String.to_integer(:cowboy_req.qs_val("since_id", req, "0"))
    include_logs = String.to_atom(:cowboy_req.qs_val("include_logs", req, "false"))
    
    # Set up SSE headers
    req = :cowboy_req.set_resp_header("content-type", "text/event-stream", req)
    req = :cowboy_req.set_resp_header("cache-control", "no-cache", req)
    req = :cowboy_req.set_resp_header("connection", "keep-alive", req)
    {:ok, req} = :cowboy_req.send_resp(200, #{}, req)
    
    # Stream events
    stream_events(req, state, tenant_id, service_id, since_id, include_logs)
  end
  
  defp stream_events(req, state, tenant_id, service_id, since_id, include_logs) do
    # Get event stream from event store
    event_stream = create_event_stream(tenant_id, service_id, since_id, include_logs)
    
    # Send events to client (real-time streaming)
    Enum.each(event_stream, fn event ->
      event_json = Jason.encode!(%{
        id: event.id,
        event_type: to_string(event.event_type),
        timestamp: DateTime.to_iso8601(event.wall_clock),
        service_id: extract_service_id(event.subject),
        payload: event.payload
      })
      
      sse_frame = "data: #{event_json}\n\n"
      :cowboy_req.send_chunk(sse_frame, req)
      
      Process.sleep(10)  # Small delay to avoid overwhelming client
    end)
    
    {:ok, req, state}
  end
end
```

---

## Integration with Existing gRPC

### Shared Infrastructure
- Both REST and gRPC handlers use same backend:
  - `Solo.Deployment.Deployer` - service lifecycle
  - `Solo.EventStore` - event streaming
  - `Solo.Registry` - service discovery
  
### Tenant Identification
- gRPC: Extracted from mTLS certificate CN field
- REST: Extracted from `X-Tenant-ID` header, falls back to mTLS

### Key Differences
| Aspect | gRPC | REST |
|--------|------|------|
| Protocol | HTTP/2 | HTTP/1.1 |
| Serialization | Protocol Buffers | JSON |
| Streaming | Bidirectional streams | Server-Sent Events |
| Authentication | mTLS only | Header + mTLS |
| Use Case | Internal services | Public APIs, web apps |

---

## Implementation Priority

### Phase 1: Core Endpoints (MVP)
1. `POST /services` - Deploy
2. `GET /services` - List
3. `GET /services/{id}` - Status
4. `DELETE /services/{id}` - Kill
5. `GET /health` - Health check

**Time**: 2-3 days
**Deliverable**: Fully functional REST API for service management

### Phase 2: Event Streaming
1. `GET /events` - Server-Sent Events
2. Query parameter filtering (service_id, since_id)
3. Event pagination and limits

**Time**: 1-2 days
**Deliverable**: Real-time event streaming via HTTP

### Phase 3: Polish & Testing
1. Error handling and validation
2. Rate limiting / load shedding
3. Integration tests
4. API documentation (OpenAPI/Swagger)

**Time**: 1-2 days
**Deliverable**: Production-ready REST API

---

## Example Usage

### Deploy a Service via REST
```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "service_id": "my-agent",
    "code": "defmodule MyAgent do\n  def start_link(_), do: {:ok, self()}\nend",
    "format": "elixir_source"
  }'
```

### List Services
```bash
curl http://localhost:8080/services \
  -H "X-Tenant-ID: acme-corp"
```

### Stream Events
```bash
curl http://localhost:8080/events \
  -H "X-Tenant-ID: acme-corp" \
  -H "Accept: text/event-stream"
```

### Get Service Status
```bash
curl http://localhost:8080/services/my-agent \
  -H "X-Tenant-ID: acme-corp"
```

### Delete Service
```bash
curl -X DELETE http://localhost:8080/services/my-agent \
  -H "X-Tenant-ID: acme-corp" \
  -d '?grace_ms=3000'
```

---

## Summary

This REST API design provides:

✅ **Feature Parity** with gRPC interface  
✅ **Familiar Patterns** for HTTP developers  
✅ **Scalable Architecture** built on existing infrastructure  
✅ **Real-time Streaming** via Server-Sent Events  
✅ **Clear Error Handling** with standard HTTP status codes  
✅ **Multi-tenant Isolation** with header-based tenant identification  
✅ **Production Ready** with proper authentication, validation, and monitoring  

The implementation uses Cowboy HTTP handlers with a clean separation of concerns, making it easy to test, maintain, and extend.
