# Solo REST API Documentation

Complete REST API reference for Solo v0.2.0.

## Quick Start

**Base URL:** `http://localhost:8080`

**Authentication:** Multi-tenant via `X-Tenant-ID` header

```bash
curl -X GET http://localhost:8080/health \
  -H "X-Tenant-ID: my-tenant"
```

---

## Endpoints

### Health & Monitoring

#### GET /health

Check system health status.

**Request:**
```bash
curl http://localhost:8080/health \
  -H "X-Tenant-ID: my-tenant"
```

**Response (200 OK):**
```json
{
  "status": "healthy",
  "services": 5,
  "events": 1234,
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### GET /metrics

Get system metrics (Prometheus compatible).

**Request:**
```bash
curl http://localhost:8080/metrics \
  -H "X-Tenant-ID: my-tenant"
```

**Response (200 OK):**
```
# HELP solo_deployments_total Total deployments
# TYPE solo_deployments_total counter
solo_deployments_total 42

# HELP solo_kills_total Total service kills
# TYPE solo_kills_total counter
solo_kills_total 3

# HELP solo_status_checks_total Total status checks
# TYPE solo_status_checks_total counter
solo_status_checks_total 156
```

---

### Service Management

#### POST /services

Deploy a new service.

**Request:**
```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "service_id": "my-agent-v1",
    "code": "defmodule MyAgent do\n  use GenServer\n  def start_link(_), do: GenServer.start_link(__MODULE__, %{})\n  def init(state), do: {:ok, state}\nend",
    "format": "elixir_source"
  }'
```

**Response (201 Created):**
```json
{
  "service_id": "my-agent-v1",
  "status": "deployed",
  "message": "Service deployed successfully",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

**Error Response (400 Bad Request):**
```json
{
  "error": "invalid_request",
  "message": "Missing required fields: code",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### GET /services

List all services for a tenant.

**Request:**
```bash
curl "http://localhost:8080/services?limit=50&offset=0&status=running" \
  -H "X-Tenant-ID: acme-corp"
```

**Query Parameters:**
- `limit` (optional, default: 100, max: 1000) - Results per page
- `offset` (optional, default: 0) - Pagination offset
- `status` (optional) - Filter by status: "running", "stopped", "unknown"

**Response (200 OK):**
```json
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
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0,
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### GET /services/{service_id}

Get detailed status of a specific service.

**Request:**
```bash
curl http://localhost:8080/services/my-agent-v1 \
  -H "X-Tenant-ID: acme-corp"
```

**Response (200 OK):**
```json
{
  "service_id": "my-agent-v1",
  "status": "running",
  "alive": true,
  "created_at": "2026-02-09T10:00:00Z",
  "memory_bytes": 1048576,
  "message_queue_len": 5,
  "reductions": 500000
}
```

**Error Response (404 Not Found):**
```json
{
  "error": "not_found",
  "message": "Service not found",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### DELETE /services/{service_id}

Kill (terminate) a service.

**Request:**
```bash
curl -X DELETE http://localhost:8080/services/my-agent-v1 \
  -H "X-Tenant-ID: acme-corp"
```

**Response (202 Accepted):**
```json
{
  "service_id": "my-agent-v1",
  "status": "killed",
  "message": "Service scheduled for termination",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

---

### Event Streaming

#### GET /events

Stream events in real-time using Server-Sent Events (SSE).

**Request:**
```bash
curl "http://localhost:8080/events?tenant_id=acme-corp&service_id=my-agent-v1&limit=10" \
  -H "X-Tenant-ID: acme-corp"
```

**Query Parameters:**
- `service_id` (optional) - Filter by service ID
- `limit` (optional, default: 100, max: 1000) - Recent events to start with

**Response (200 OK):**
```
data: {"id":1,"event_type":"service_deployed","timestamp":"2026-02-09T10:00:00Z","subject":"acme-corp/my-agent-v1","payload":{"service_id":"my-agent-v1"}}

data: {"id":2,"event_type":"service_started","timestamp":"2026-02-09T10:00:01Z","subject":"acme-corp/my-agent-v1","payload":{}}

...stream continues...
```

**Usage with curl:**
```bash
# Stream to file
curl http://localhost:8080/events \
  -H "X-Tenant-ID: acme-corp" >> events.stream

# Stream with jq filtering
curl http://localhost:8080/events \
  -H "X-Tenant-ID: acme-corp" | grep "data:" | sed 's/data: //' | jq .
```

---

### Secrets Management

#### POST /secrets

Store an encrypted secret.

**Request:**
```bash
curl -X POST http://localhost:8080/secrets \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "key": "DATABASE_PASSWORD",
    "value": "super-secret-password-123"
  }'
```

**Response (201 Created):**
```json
{
  "key": "DATABASE_PASSWORD",
  "status": "stored",
  "message": "Secret stored successfully",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### GET /secrets/{key}

Check if a secret exists (doesn't return the value for security).

**Request:**
```bash
curl http://localhost:8080/secrets/DATABASE_PASSWORD \
  -H "X-Tenant-ID: acme-corp"
```

**Response (200 OK):**
```json
{
  "key": "DATABASE_PASSWORD",
  "exists": true,
  "timestamp": "2026-02-09T14:30:00Z"
}
```

**Error Response (404 Not Found):**
```json
{
  "error": "not_found",
  "message": "Secret key not found: DATABASE_PASSWORD",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### GET /secrets

List all secret keys for a tenant (not values).

**Request:**
```bash
curl "http://localhost:8080/secrets?limit=50&offset=0" \
  -H "X-Tenant-ID: acme-corp"
```

**Query Parameters:**
- `limit` (optional, default: 100, max: 1000)
- `offset` (optional, default: 0)

**Response (200 OK):**
```json
{
  "secrets": [
    "DATABASE_PASSWORD",
    "API_KEY",
    "JWT_SECRET"
  ],
  "total": 3,
  "limit": 50,
  "offset": 0,
  "timestamp": "2026-02-09T14:30:00Z"
}
```

#### DELETE /secrets/{key}

Delete (revoke) a secret.

**Request:**
```bash
curl -X DELETE http://localhost:8080/secrets/DATABASE_PASSWORD \
  -H "X-Tenant-ID: acme-corp"
```

**Response (200 OK):**
```json
{
  "key": "DATABASE_PASSWORD",
  "status": "deleted",
  "message": "Secret deleted successfully",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

---

### Logs Streaming

#### GET /logs

Stream logs in real-time using Server-Sent Events (SSE).

**Request:**
```bash
curl "http://localhost:8080/logs?service_id=my-agent-v1&level=ERROR&limit=50" \
  -H "X-Tenant-ID: acme-corp"
```

**Query Parameters:**
- `service_id` (optional) - Filter by service ID
- `level` (optional) - Filter by level: DEBUG, INFO, WARN, ERROR
- `limit` (optional, default: 100, max: 1000) - Recent logs to start with

**Response (200 OK):**
```
data: {"timestamp":"2026-02-09T14:25:00Z","tenant_id":"acme-corp","service_id":"my-agent-v1","level":"INFO","message":"Service started successfully"}

data: {"timestamp":"2026-02-09T14:26:00Z","tenant_id":"acme-corp","service_id":"my-agent-v1","level":"WARN","message":"Memory usage approaching limit"}

...stream continues...
```

---

## Error Handling

All endpoints return consistent error responses:

**400 Bad Request** - Invalid parameters:
```json
{
  "error": "invalid_request",
  "message": "Missing required fields: key",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

**404 Not Found** - Resource doesn't exist:
```json
{
  "error": "not_found",
  "message": "Service not found",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

**500 Internal Server Error** - Server error:
```json
{
  "error": "internal_error",
  "message": "Service deployment failed: compilation error",
  "timestamp": "2026-02-09T14:30:00Z"
}
```

---

## Multi-Tenancy

All endpoints support multi-tenancy via the `X-Tenant-ID` header:

```bash
curl http://localhost:8080/services \
  -H "X-Tenant-ID: tenant-a"

curl http://localhost:8080/services \
  -H "X-Tenant-ID: tenant-b"
```

Services are completely isolated per tenant. Tenant IDs must be:
- Alphanumeric plus underscores (a-z, A-Z, 0-9, _)
- 1-128 characters long

---

## Server-Sent Events (SSE)

The `/events` and `/logs` endpoints use Server-Sent Events for real-time streaming:

**Connection stays open** - Data flows continuously
**Automatic reconnection** - Client automatically reconnects on disconnect
**Keep-alive heartbeat** - Server sends `:` every 60 seconds to keep connection alive
**Event format** - Each event is prefixed with `data: ` followed by JSON

**Example streaming client (JavaScript):**
```javascript
const eventSource = new EventSource(
  'http://localhost:8080/events?limit=10',
  { headers: { 'X-Tenant-ID': 'my-tenant' } }
);

eventSource.onmessage = (e) => {
  const event = JSON.parse(e.data);
  console.log(`Event ${event.id}: ${event.event_type}`);
};

eventSource.onerror = (e) => {
  console.error('Connection error:', e);
  eventSource.close();
};
```

---

## Rate Limiting

No explicit rate limiting in v0.2.0, but:
- Gateway uses load shedding per tenant
- Each tenant gets fair share of resources
- Requests rejected if tenant exceeds limits

See DEPLOYMENT.md for configuring tenant limits.

---

## Pagination

List endpoints support cursor-based pagination:

```bash
# Get first 10
curl "http://localhost:8080/services?limit=10&offset=0" \
  -H "X-Tenant-ID: acme-corp"

# Get next 10
curl "http://localhost:8080/services?limit=10&offset=10" \
  -H "X-Tenant-ID: acme-corp"
```

**Response:**
```json
{
  "services": [...],
  "total": 100,      // Total items available
  "limit": 10,       // Items per page
  "offset": 0,       // Current offset
  "timestamp": "2026-02-09T14:30:00Z"
}
```

---

## Content Types

All endpoints use JSON:
- **Request:** `Content-Type: application/json`
- **Response:** `Content-Type: application/json`
- **Streaming:** `Content-Type: text/event-stream` (for SSE endpoints)

---

## Status Codes

| Code | Meaning | When Used |
|------|---------|-----------|
| 200 | OK | Successful GET request |
| 201 | Created | Successful POST request (resource created) |
| 202 | Accepted | Async operation started (DELETE) |
| 204 | No Content | Successful with no response body |
| 400 | Bad Request | Invalid parameters or validation error |
| 404 | Not Found | Resource doesn't exist |
| 500 | Internal Server Error | Server-side error during processing |

---

## Examples

### Deploy and Monitor a Service

```bash
# 1. Deploy service
SERVICE_ID="calculator"
CODE='defmodule Calculator do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, 0)
  def init(state), do: {:ok, state}
end'

curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: my-tenant" \
  -d "{\"service_id\": \"$SERVICE_ID\", \"code\": \"$CODE\", \"format\": \"elixir_source\"}"

# 2. List services
curl http://localhost:8080/services \
  -H "X-Tenant-ID: my-tenant" | jq '.services[] | {service_id, status}'

# 3. Get service status
curl http://localhost:8080/services/$SERVICE_ID \
  -H "X-Tenant-ID: my-tenant" | jq '.memory_bytes, .message_queue_len'

# 4. Stream events for service
curl "http://localhost:8080/events?service_id=$SERVICE_ID" \
  -H "X-Tenant-ID: my-tenant" | grep "data:" | head -5

# 5. Kill service
curl -X DELETE http://localhost:8080/services/$SERVICE_ID \
  -H "X-Tenant-ID: my-tenant"
```

### Store and List Secrets

```bash
# 1. Store secret
curl -X POST http://localhost:8080/secrets \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: my-tenant" \
  -d '{"key": "DB_URL", "value": "postgres://localhost:5432/mydb"}'

# 2. List secrets
curl http://localhost:8080/secrets \
  -H "X-Tenant-ID: my-tenant" | jq '.secrets'

# 3. Check if secret exists
curl http://localhost:8080/secrets/DB_URL \
  -H "X-Tenant-ID: my-tenant" | jq '.exists'

# 4. Delete secret
curl -X DELETE http://localhost:8080/secrets/DB_URL \
  -H "X-Tenant-ID: my-tenant"
```

---

## Performance

Typical response times (measured on development machine):
- Health check: < 1ms
- List services: < 50ms (for 100 services)
- Deploy service: 100-500ms (depends on code size)
- Stream events: Immediate (first event within 100ms)
- Get status: < 10ms

See DEPLOYMENT.md for production performance tuning.

---

## See Also

- [Elixir/Erlang API Documentation](OTP_API.md)
- [Architecture Guide](ARCHITECTURE.md)
- [Deployment Guide](DEPLOYMENT.md)
- [CLI Guide](../CLI_GUIDE.md)
