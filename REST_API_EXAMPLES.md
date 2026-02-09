# Solo REST API Usage Examples

This document provides practical examples of using the Solo REST API with `curl` and other HTTP clients.

## Prerequisites

- Solo gateway running on `localhost:8080`
- `curl` installed
- `jq` for JSON formatting (optional)

---

## 1. Service Management Examples

### 1.1 Deploy a Service

**Deploy a simple Elixir service:**

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "service_id": "my-agent-v1",
    "code": "defmodule MyAgent do\n  def handle(msg), do: {:ok, msg}\nend",
    "format": "elixir_source"
  }' | jq .
```

**Response (201 Created):**

```json
{
  "service_id": "my-agent-v1",
  "status": "deployed",
  "message": "Service deployed successfully",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

**Deploy with a more complex agent:**

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "service_id": "calculator-agent",
    "code": "defmodule CalculatorAgent do\n  use GenServer\n\n  def start_link(_), do: GenServer.start_link(__MODULE__, %{result: 0})\n\n  def handle_call({:add, x}, _from, state) do\n    new_result = state.result + x\n    {:reply, new_result, %{state | result: new_result}}\n  end\n\n  def handle_call({:multiply, x}, _from, state) do\n    new_result = state.result * x\n    {:reply, new_result, %{state | result: new_result}}\n  end\nend",
    "format": "elixir_source"
  }' | jq .
```

---

### 1.2 List Services

**List all services for a tenant:**

```bash
curl http://localhost:8080/services \
  -H "X-Tenant-ID: acme-corp" | jq .
```

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
    },
    {
      "service_id": "calculator-agent",
      "status": "running",
      "alive": true,
      "created_at": "2026-02-09T10:05:00Z",
      "metadata": {
        "memory_bytes": 2097152,
        "message_queue_len": 3,
        "reductions": 150000
      }
    }
  ],
  "total": 2,
  "limit": 100,
  "offset": 0,
  "timestamp": "2026-02-09T12:34:56Z"
}
```

**List with pagination:**

```bash
curl "http://localhost:8080/services?limit=10&offset=0" \
  -H "X-Tenant-ID: acme-corp" | jq .
```

**Filter by status:**

```bash
curl "http://localhost:8080/services?status=running" \
  -H "X-Tenant-ID: acme-corp" | jq .
```

---

### 1.3 Get Service Status

**Get detailed status of a service:**

```bash
curl http://localhost:8080/services/my-agent-v1 \
  -H "X-Tenant-ID: acme-corp" | jq .
```

**Response (200 OK):**

```json
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
      "payload": {
        "usage": 98500
      }
    }
  ],
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

### 1.4 Delete (Kill) Service

**Kill a service gracefully (5 second grace period):**

```bash
curl -X DELETE http://localhost:8080/services/my-agent-v1 \
  -H "X-Tenant-ID: acme-corp" | jq .
```

**Response (202 Accepted):**

```json
{
  "service_id": "my-agent-v1",
  "status": "terminating",
  "message": "Service termination initiated",
  "grace_period_ms": 5000,
  "timestamp": "2026-02-09T12:34:56Z"
}
```

**Kill with custom grace period:**

```bash
curl -X DELETE "http://localhost:8080/services/my-agent-v1?grace_ms=3000" \
  -H "X-Tenant-ID: acme-corp" | jq .
```

**Force kill (immediate):**

```bash
curl -X DELETE "http://localhost:8080/services/my-agent-v1?force=true" \
  -H "X-Tenant-ID: acme-corp" | jq .
```

---

## 2. Monitoring Examples

### 2.1 Health Check

**Check system health:**

```bash
curl http://localhost:8080/health | jq .
```

**Response (200 OK):**

```json
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
```

**Response (503 Service Unavailable):**

```json
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

---

### 2.2 Stream Events (Server-Sent Events)

**Stream all events for a tenant:**

```bash
curl http://localhost:8080/events \
  -H "X-Tenant-ID: acme-corp" \
  -H "Accept: text/event-stream"
```

**Response Stream:**

```
data: {"id":1001,"event_type":"service_started","timestamp":"2026-02-09T10:00:00Z","service_id":"my-agent-v1","payload":{}}

data: {"id":1002,"event_type":"atom_usage_high","timestamp":"2026-02-09T10:00:05Z","service_id":"my-agent-v1","payload":{"usage":98000}}

data: {"id":1003,"event_type":"service_message_sent","timestamp":"2026-02-09T10:00:10Z","service_id":"my-agent-v1","payload":{"message":"request processed","queue_len":0}}
```

**Stream events for a specific service:**

```bash
curl "http://localhost:8080/events?service_id=my-agent-v1" \
  -H "X-Tenant-ID: acme-corp"
```

**Stream events starting from a specific ID:**

```bash
curl "http://localhost:8080/events?since_id=1000" \
  -H "X-Tenant-ID: acme-corp"
```

**Include verbose logging events:**

```bash
curl "http://localhost:8080/events?include_logs=true" \
  -H "X-Tenant-ID: acme-corp"
```

**JavaScript client example:**

```javascript
// Connect to event stream
const eventSource = new EventSource(
  'http://localhost:8080/events?service_id=my-agent-v1',
  {
    headers: {
      'X-Tenant-ID': 'acme-corp'
    }
  }
);

// Handle incoming events
eventSource.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Event received:', data);
  
  // Update UI with event data
  updateServiceStatus(data);
};

// Handle connection errors
eventSource.onerror = (error) => {
  console.error('Connection error:', error);
  // Attempt to reconnect (EventSource handles this automatically)
};

// Listen for specific event types
eventSource.addEventListener('service_started', (event) => {
  const data = JSON.parse(event.data);
  console.log('Service started:', data.service_id);
});
```

**Python client example:**

```python
import requests
import json

headers = {'X-Tenant-ID': 'acme-corp'}
url = 'http://localhost:8080/events'

# Stream events using requests library
with requests.get(url, headers=headers, stream=True) as r:
    for line in r.iter_lines():
        if line:
            # Remove 'data: ' prefix
            if line.startswith(b'data: '):
                event_data = json.loads(line[6:])
                print(f"Event {event_data['id']}: {event_data['event_type']}")
```

---

## 3. Error Examples

### 3.1 Missing Tenant ID

```bash
curl http://localhost:8080/services
```

**Response (400 Bad Request):**

```json
{
  "error": "missing_tenant_id",
  "message": "X-Tenant-ID header required",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

### 3.2 Invalid Service ID

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "service_id": "invalid@service#id",
    "code": "defmodule Test do end",
    "format": "elixir_source"
  }'
```

**Response (400 Bad Request):**

```json
{
  "error": "invalid_service_id",
  "message": "Service ID contains invalid characters",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

### 3.3 Service Not Found

```bash
curl http://localhost:8080/services/nonexistent \
  -H "X-Tenant-ID: acme-corp"
```

**Response (404 Not Found):**

```json
{
  "error": "not_found",
  "message": "Service 'nonexistent' not found",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

### 3.4 Invalid JSON

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d 'invalid json'
```

**Response (400 Bad Request):**

```json
{
  "error": "invalid_json",
  "message": "Invalid JSON at position 5",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

### 3.5 Missing Required Fields

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: acme-corp" \
  -d '{
    "service_id": "my-service"
  }'
```

**Response (400 Bad Request):**

```json
{
  "error": "invalid_request",
  "message": "Missing required fields: code",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

---

## 4. Tenant Isolation Examples

### Example 1: Two Different Tenants

**Tenant 1 deploys a service:**

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: tenant-1" \
  -d '{
    "service_id": "agent",
    "code": "defmodule Agent1 do end",
    "format": "elixir_source"
  }'
```

**Tenant 2 deploys a service with same ID (allowed):**

```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: tenant-2" \
  -d '{
    "service_id": "agent",
    "code": "defmodule Agent2 do end",
    "format": "elixir_source"
  }'
```

**Tenant 1 can only see their own services:**

```bash
curl http://localhost:8080/services \
  -H "X-Tenant-ID: tenant-1"
```

Returns only tenant-1's services, not tenant-2's.

---

## 5. Advanced Workflows

### 5.1 Deploy, Monitor, and Cleanup

```bash
#!/bin/bash

TENANT_ID="my-tenant"
SERVICE_ID="temp-worker"
API="http://localhost:8080"

# Deploy service
echo "Deploying service..."
curl -X POST $API/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: $TENANT_ID" \
  -d '{
    "service_id": "'$SERVICE_ID'",
    "code": "defmodule Worker do\n  def process(data), do: {:ok, data}\nend",
    "format": "elixir_source"
  }'

# Wait a bit
sleep 2

# Check status
echo "Checking service status..."
curl $API/services/$SERVICE_ID \
  -H "X-Tenant-ID: $TENANT_ID" | jq '.status'

# Stream events in background
echo "Streaming events..."
curl "$API/events?service_id=$SERVICE_ID" \
  -H "X-Tenant-ID: $TENANT_ID" &
EVENT_PID=$!

# Let it run for 10 seconds
sleep 10

# Kill the event stream
kill $EVENT_PID

# Shutdown the service
echo "Shutting down service..."
curl -X DELETE "$API/services/$SERVICE_ID" \
  -H "X-Tenant-ID: $TENANT_ID"
```

---

### 5.2 Health Monitoring Script

```bash
#!/bin/bash

API="http://localhost:8080"

while true; do
  # Check system health
  health=$(curl -s $API/health | jq '.status')
  
  if [ "$health" == '"healthy"' ]; then
    echo "✓ System is healthy"
  else
    echo "✗ System is unhealthy!"
    curl -s $API/health | jq '.'
  fi
  
  sleep 30
done
```

---

## 6. Integration Examples

### 6.1 TypeScript/Node.js Client

```typescript
import fetch from 'node-fetch';

class SoloAPIClient {
  private baseURL: string;
  private tenantID: string;

  constructor(baseURL: string = 'http://localhost:8080', tenantID: string) {
    this.baseURL = baseURL;
    this.tenantID = tenantID;
  }

  private headers() {
    return {
      'Content-Type': 'application/json',
      'X-Tenant-ID': this.tenantID
    };
  }

  async deployService(serviceId: string, code: string) {
    const response = await fetch(`${this.baseURL}/services`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({
        service_id: serviceId,
        code,
        format: 'elixir_source'
      })
    });
    return response.json();
  }

  async listServices() {
    const response = await fetch(`${this.baseURL}/services`, {
      headers: this.headers()
    });
    return response.json();
  }

  async getServiceStatus(serviceId: string) {
    const response = await fetch(
      `${this.baseURL}/services/${serviceId}`,
      { headers: this.headers() }
    );
    return response.json();
  }

  async killService(serviceId: string, gracePeriodMs = 5000) {
    const response = await fetch(
      `${this.baseURL}/services/${serviceId}?grace_ms=${gracePeriodMs}`,
      { method: 'DELETE', headers: this.headers() }
    );
    return response.json();
  }

  streamEvents(serviceId?: string) {
    const url = serviceId
      ? `${this.baseURL}/events?service_id=${serviceId}`
      : `${this.baseURL}/events`;
    
    return new EventSource(url, {
      headers: this.headers() as any
    });
  }
}

// Usage
const client = new SoloAPIClient('http://localhost:8080', 'my-tenant');

// Deploy a service
const result = await client.deployService('my-agent', `
  defmodule MyAgent do
    def start_link(_), do: {:ok, self()}
  end
`);
console.log('Deployed:', result);

// List services
const services = await client.listServices();
console.log('Services:', services);

// Stream events
const eventStream = client.streamEvents('my-agent');
eventStream.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Event:', data);
};
```

---

## Summary

The Solo REST API provides:

- ✅ **Full feature parity** with gRPC interface
- ✅ **Easy HTTP/JSON** access for web clients
- ✅ **Real-time streaming** via Server-Sent Events
- ✅ **Multi-tenant isolation** via headers
- ✅ **Comprehensive error handling** with standard HTTP codes
- ✅ **Production-ready** implementation

All examples above use standard HTTP tools and can be integrated into any modern application.
