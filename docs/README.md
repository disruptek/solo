# Solo Documentation

Welcome to Solo! This directory contains comprehensive documentation for Solo v0.2.0.

## Quick Navigation

**Getting Started?** Start here:
1. Read [../README.md](../README.md) for overview
2. Follow the [Cheatsheet](#cheatsheet) below
3. Run the [Quick Start](#quick-start)
4. Check [REST_API.md](REST_API.md) or [OTP_API.md](OTP_API.md)

**Looking for specific docs?**
- **[Cheatsheet](#cheatsheet)** - Common operations quick reference
- **[REST_API.md](REST_API.md)** - HTTP REST API (curl, JavaScript, etc.)
- **[OTP_API.md](OTP_API.md)** - Elixir/Erlang API reference
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - System design and components
- **[DEPLOYMENT.md](DEPLOYMENT.md)** - Production deployment guide
- **[ROADMAP.md](ROADMAP.md)** - Future features and planned work

---

## Cheatsheet

### Deploy & Manage Services

**Deploy a service:**
```bash
# HTTP/REST
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: my-tenant" \
  -d '{
    "service_id": "my-service",
    "code": "defmodule MyService do\n  use GenServer\n  def start_link(_), do: GenServer.start_link(__MODULE__, %{})\n  def init(state), do: {:ok, state}\nend",
    "format": "elixir_source"
  }'

# Elixir
{:ok, pid} = Solo.Deployment.Deployer.deploy(%{
  tenant_id: "my-tenant",
  service_id: "my-service",
  code: "defmodule MyService do ... end",
  format: :elixir_source
})

# CLI
solo deploy my-service.ex --tenant=my-tenant
```

**List services:**
```bash
curl http://localhost:8080/services \
  -H "X-Tenant-ID: my-tenant" | jq '.services[] | {service_id, status, alive}'

# Or Elixir
services = Solo.Deployment.Deployer.list("my-tenant")
```

**Get service status:**
```bash
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant" | jq '.memory_bytes, .message_queue_len'

# Or Elixir
status = Solo.Deployment.Deployer.status("my-tenant", "my-service")
```

**Kill service:**
```bash
curl -X DELETE http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant"

# Or Elixir
:ok = Solo.Deployment.Deployer.kill("my-tenant", "my-service")

# Or CLI
solo kill my-service --tenant=my-tenant
```

### Secrets Management

**Store a secret:**
```bash
curl -X POST http://localhost:8080/secrets \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: my-tenant" \
  -d '{"key": "DB_PASSWORD", "value": "secret123"}'

# Or Elixir
:ok = Solo.Vault.store("my-tenant", "DB_PASSWORD", "secret123", "encryption_key")

# Or CLI
solo secrets set DB_PASSWORD secret123 --tenant=my-tenant
```

**List secrets:**
```bash
curl http://localhost:8080/secrets \
  -H "X-Tenant-ID: my-tenant" | jq '.secrets'

# Or Elixir
{:ok, secrets} = Solo.Vault.list_secrets("my-tenant")
```

**Delete a secret:**
```bash
curl -X DELETE http://localhost:8080/secrets/DB_PASSWORD \
  -H "X-Tenant-ID: my-tenant"

# Or Elixir
:ok = Solo.Vault.revoke("my-tenant", "DB_PASSWORD")

# Or CLI
solo secrets delete DB_PASSWORD --tenant=my-tenant
```

### Event Streaming

**Stream all events:**
```bash
curl "http://localhost:8080/events?limit=10" \
  -H "X-Tenant-ID: my-tenant" | grep "data:" | head -5

# Or Elixir
events = Solo.EventStore.stream(tenant_id: "my-tenant", limit: 10)
|> Enum.to_list()
```

**Filter events:**
```bash
# By event type
curl "http://localhost:8080/events?limit=100" \
  -H "X-Tenant-ID: my-tenant" | grep "service_deployed"

# Or Elixir
deployments = Solo.EventStore.filter(event_type: :service_deployed)
```

**Stream logs in real-time:**
```bash
curl "http://localhost:8080/logs?service_id=my-service&level=ERROR" \
  -H "X-Tenant-ID: my-tenant"

# Or Elixir (listen for events)
events = Solo.EventStore.stream(
  tenant_id: "my-tenant",
  service_id: "my-service"
)
Stream.each(events, &IO.inspect/1) |> Stream.run()
```

### Capabilities & Access Control

**Grant a capability:**
```elixir
{:ok, token} = Solo.Capability.Manager.grant("my-tenant", :deploy, %{
  service_id: "my-service"
})

IO.puts("Token: #{token}")
```

**Verify capability:**
```elixir
case Solo.Capability.Manager.verify("my-tenant", token, :deploy) do
  {:ok, _} -> IO.puts("Permission granted!")
  {:error, reason} -> IO.puts("Permission denied: #{reason}")
end
```

**Revoke capability:**
```elixir
:ok = Solo.Capability.Manager.revoke(token)
```

### System Health

**Check health:**
```bash
curl http://localhost:8080/health \
  -H "X-Tenant-ID: my-tenant" | jq '.status'

# Or Elixir
# (Check if Solo.Application is running)
```

**Get metrics:**
```bash
curl http://localhost:8080/metrics \
  -H "X-Tenant-ID: my-tenant"
```

---

## Quick Start

### Installation

```bash
git clone https://github.com/disruptek/solo.git
cd solo
export PATH="$HOME/.asdf/installs/erlang/28.3.1/bin:$HOME/.asdf/installs/elixir/1.19.5/bin:$PATH"
mix deps.get
mix compile
mix test
```

### Start the Server

**Option 1: Interactive console**
```bash
iex -S mix
```

**Option 2: Background server**
```bash
mix run --no-halt &
```

### Test It Works

```bash
# In another terminal
curl http://localhost:8080/health \
  -H "X-Tenant-ID: test-tenant"
```

Response should be:
```json
{
  "status": "healthy",
  "services": 0,
  "events": 0,
  "timestamp": "2026-02-09T14:30:00Z"
}
```

### Deploy Your First Service

```bash
# 1. Create a test service file
cat > test_service.ex << 'EOF'
defmodule TestService do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  def init(state) do
    IO.puts("TestService started!")
    {:ok, state}
  end
end
EOF

# 2. Deploy it
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: my-tenant" \
  -d '{
    "service_id": "test-service",
    "code": "'$(cat test_service.ex | sed 's/$/\\n/' | tr -d '\n')'",
    "format": "elixir_source"
  }' | jq .

# 3. Check status
curl http://localhost:8080/services/test-service \
  -H "X-Tenant-ID: my-tenant" | jq '.alive'

# Should output: true
```

---

## Common Patterns

### Multi-Tenant Usage

Each tenant is completely isolated:

```bash
# Tenant A
curl http://localhost:8080/services \
  -H "X-Tenant-ID: tenant-a"

# Tenant B (sees different services)
curl http://localhost:8080/services \
  -H "X-Tenant-ID: tenant-b"
```

### Batch Operations

```elixir
# Deploy multiple services
Enum.each(1..10, fn i ->
  Solo.Deployment.Deployer.deploy(%{
    tenant_id: "my-tenant",
    service_id: "service_#{i}",
    code: "defmodule Service#{i} do; end",
    format: :elixir_source
  })
end)

# List all
services = Solo.Deployment.Deployer.list("my-tenant")
```

### Event Replay

```elixir
# Get all events since a specific event
events = Solo.EventStore.stream(
  tenant_id: "my-tenant",
  since_id: 100  # Start after event 100
)
|> Enum.to_list()

# Filter specific types
deployments = Solo.EventStore.filter(
  tenant_id: "my-tenant",
  event_type: :service_deployed
)
```

---

## Debugging

### Check Service Status

```bash
# Is it running?
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant" | jq '.alive'

# How much memory?
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant" | jq '.memory_bytes'

# How many messages in queue?
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant" | jq '.message_queue_len'
```

### Watch Events

```bash
# Real-time event stream
curl "http://localhost:8080/events?limit=50" \
  -H "X-Tenant-ID: my-tenant" | while read line; do
  echo "$line" | grep "data:" | sed 's/data: //' | jq '.'
done
```

### View Recent Events

```elixir
# Get last 20 events
events = Solo.EventStore.stream(tenant_id: "my-tenant", limit: 20)
|> Enum.reverse()
|> Enum.each(&IO.inspect/1)
```

---

## Performance Tips

1. **Use HTTP/REST for external clients** - Better for network communication
2. **Use Elixir API for internal operations** - Faster, no serialization
3. **Stream events in batches** - Use `limit` parameter to paginate
4. **Monitor memory per service** - Use `/services/{id}` status endpoint
5. **Use capabilities for security** - Better than passing around secrets

---

## Troubleshooting

### Service deployment fails

**Check compilation error:**
```bash
curl -X POST http://localhost:8080/services \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: my-tenant" \
  -d '{...}' | jq '.error, .message'
```

**Common issues:**
- Syntax error in code
- Missing module definition
- Trying to import non-standard modules

### Can't find service

```bash
# List all services for tenant
curl http://localhost:8080/services \
  -H "X-Tenant-ID: my-tenant" | jq '.services[].service_id'

# Check exact tenant ID
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: CORRECT_TENANT_ID" | jq '.service_id'
```

### Service not responding

**Check if alive:**
```bash
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant" | jq '.alive'
```

**Check message queue:**
```bash
curl http://localhost:8080/services/my-service \
  -H "X-Tenant-ID: my-tenant" | jq '.message_queue_len'
```

If queue is full, service is stuck. Kill and redeploy.

---

## Next Steps

- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Understand the design
- **[OTP_API.md](OTP_API.md)** - Complete API reference
- **[REST_API.md](REST_API.md)** - HTTP/REST documentation
- **[DEPLOYMENT.md](DEPLOYMENT.md)** - Production setup
- **[ROADMAP.md](ROADMAP.md)** - Future features

---

## Getting Help

- Check [REST_API.md](REST_API.md) for endpoint examples
- Read [OTP_API.md](OTP_API.md) for Elixir function signatures
- See [DEPLOYMENT.md](DEPLOYMENT.md) for configuration
- File an issue on GitHub: https://github.com/disruptek/solo/issues

---

**Ready to go?** Start with the [Quick Start](#quick-start)!
