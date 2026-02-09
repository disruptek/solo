# Solo CLI Guide

## Overview

The Solo CLI (`solo`) is a command-line interface for managing the Solo kernel and its services. It provides direct access to deployment, service management, and monitoring capabilities.

## Installation

Build the CLI executable:

```bash
mix escript.build
```

This creates a `solo` executable in the project root.

Install globally (optional):

```bash
cp solo /usr/local/bin/
chmod +x /usr/local/bin/solo
```

## Configuration

### Environment Variables

- `SOLO_TENANT` - Default tenant ID (default: `default_tenant`)
- `SOLO_HOST` - Solo server hostname (default: `localhost`)
- `SOLO_HTTP_PORT` - HTTP API port (default: `8080`)

### HTTP API Endpoint

The CLI communicates with the HTTP REST API on port 8080 by default.

Ensure the Solo server is running:

```bash
mix run --no-halt
```

## Commands

### solo version

Display the CLI version.

```bash
solo version
# Output: Solo 0.2.0
```

### solo help [COMMAND]

Display help for a command or general help.

```bash
solo help
solo help deploy
solo help status
```

### solo deploy

Deploy a new service from source code.

```bash
solo deploy <service.ex> [--tenant=TENANT_ID] [--service-id=SERVICE_ID]
```

**Options:**
- `--tenant=TENANT_ID` - Tenant ID (default: `SOLO_TENANT` env var or `default_tenant`)
- `--service-id=SERVICE_ID` - Service ID (default: basename of file)

**Examples:**

```bash
# Deploy with defaults
solo deploy myservice.ex

# Deploy to specific tenant
solo deploy myservice.ex --tenant=acme

# Deploy with custom service ID
solo deploy myservice.ex --service-id=api --tenant=acme

# Deploy with environment variable
SOLO_TENANT=acme solo deploy myservice.ex --service-id=api
```

**Service File Format:**

The service file should be valid Elixir code with a module that implements the GenServer behavior:

```elixir
defmodule MyService do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    {:ok, opts}
  end

  def handle_call(:status, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast({:log, message}, state) do
    IO.puts(message)
    {:noreply, state}
  end
end
```

### solo status

Get service status or list all services.

```bash
solo status [--tenant=TENANT_ID] [--service-id=SERVICE_ID]
```

**Options:**
- `--tenant=TENANT_ID` - Tenant ID
- `--service-id=SERVICE_ID` - Specific service ID (omit to list all)

**Examples:**

```bash
# Get status for one service
solo status --tenant=acme --service-id=api

# List all services for a tenant
solo status --tenant=acme
SOLO_TENANT=acme solo status

# List services for default tenant
solo status
```

**Output:**

```
Service: api
  Status: running
  Memory: 5MB
  Messages: 0
  Reductions: 1234567
```

### solo list

List all services for a tenant.

```bash
solo list [--tenant=TENANT_ID]
```

**Options:**
- `--tenant=TENANT_ID` - Tenant ID (default: `SOLO_TENANT` env var)

**Examples:**

```bash
solo list --tenant=acme

Services for tenant acme:
  ✓ api
  ✓ worker
  ✗ legacy_service
```

### solo kill

Kill a running service.

```bash
solo kill <service_id> [--tenant=TENANT_ID] [--force]
```

**Options:**
- `--tenant=TENANT_ID` - Tenant ID
- `--force` - Force kill without graceful shutdown

**Examples:**

```bash
# Graceful kill with 5 second timeout
solo kill api --tenant=acme

# Force kill immediately
solo kill api --tenant=acme --force

# Using environment variable
SOLO_TENANT=acme solo kill api
```

### solo health

Get system health status.

```bash
solo health [--json]
```

**Options:**
- `--json` - Output in JSON format (default: human-readable)

**Examples:**

```bash
# Human-readable output
solo health

# JSON output
solo health --json
```

**Output:**

```
Solo Health Status
  Status: healthy
  Version: 0.2.0
  Uptime: 2h 15m
  Memory: 256MB
  Processes: 1234
```

### solo metrics

Display system metrics.

```bash
solo metrics [--json]
```

**Options:**
- `--json` - Output in JSON format

**Examples:**

```bash
solo metrics
solo metrics --json
```

**Output:**

```
Solo Metrics
  Timestamp: 1739028000000
  Uptime: 2h 15m
  Memory: 256MB
  Processes: 1234
```

### solo logs (Coming in v0.3.0)

View service logs.

```bash
solo logs [--tenant=TENANT_ID] [--service-id=SERVICE_ID] [--tail=N]
```

**Options:**
- `--tenant=TENANT_ID` - Tenant ID
- `--service-id=SERVICE_ID` - Service ID (optional, shows all logs if omitted)
- `--tail=N` - Show last N lines (default: 50)

### solo secrets (Coming in v0.3.0)

Manage secrets for a service.

```bash
solo secrets get <key> [--tenant=TENANT_ID]
solo secrets set <key> <value> [--tenant=TENANT_ID]
solo secrets delete <key> [--tenant=TENANT_ID]
```

**Examples:**

```bash
solo secrets set DB_URL postgres://localhost/mydb --tenant=acme
solo secrets get DB_URL --tenant=acme
solo secrets delete DB_URL --tenant=acme
```

## Common Workflows

### Deploy a new service

```bash
# 1. Create service file
cat > myservice.ex << 'EOF'
defmodule MyService do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, opts}
end
EOF

# 2. Deploy to Solo
solo deploy myservice.ex --tenant=acme --service-id=myservice

# 3. Verify deployment
solo status --tenant=acme --service-id=myservice

# 4. See all services
solo list --tenant=acme
```

### Monitor a running system

```bash
# Check health
solo health

# View metrics
solo metrics

# List all services
solo list --tenant=acme

# Check specific service
solo status --tenant=acme --service-id=api
```

### Troubleshooting

```bash
# Check if Solo is running
solo health

# View service status with details
solo status --tenant=acme --service-id=api

# View recent logs (coming in v0.3.0)
solo logs --tenant=acme --service-id=api --tail=100

# Kill stuck service (graceful first, then force if needed)
solo kill api --tenant=acme
sleep 5
solo kill api --tenant=acme --force
```

## Error Handling

### Connection Errors

If you see "Connection error: ...":

1. Ensure Solo server is running: `mix run --no-halt`
2. Check HTTP port: `SOLO_HTTP_PORT=8080` (default)
3. Check hostname: `SOLO_HOST=localhost` (default)

### Tenant/Service Not Found

If you see "Error: Service not found":

1. Verify tenant ID: `SOLO_TENANT=acme solo list`
2. Verify service exists: `solo status --tenant=acme`
3. Check service ID spelling

### Permission Errors

Solo uses tenant isolation. Ensure you're using the correct tenant:

```bash
SOLO_TENANT=acme solo status  # Correct
solo status --tenant=acme      # Also correct
SOLO_TENANT=other solo status  # Wrong tenant
```

## Tips and Tricks

### Set default tenant

```bash
export SOLO_TENANT=acme
solo deploy myservice.ex              # Uses acme tenant
solo status                           # Lists acme services
solo kill api                         # Kills api in acme tenant
```

### JSON output for scripting

```bash
# Get metrics in JSON
solo metrics --json | jq '.uptime_ms'

# Parse health status
solo health --json | jq '.status'
```

### Batch operations

```bash
# Deploy multiple services
for service in service1.ex service2.ex service3.ex; do
  solo deploy "$service" --tenant=acme
done

# Kill all services (coming: bulk operations)
solo list --tenant=acme | grep "✓" | awk '{print $2}' | while read svc; do
  solo kill "$svc" --tenant=acme
done
```

## Environment Setup

### Docker

```dockerfile
FROM elixir:1.19

WORKDIR /app
COPY . .

RUN mix deps.get && \
    mix escript.build

ENTRYPOINT ["/app/solo"]
```

### Shell Completion (Future)

Bash completion coming in v0.3.0:

```bash
source <(solo completion bash)
```

## Versioning

The CLI version matches the Solo kernel version. Both are updated together.

```bash
solo version
# Solo 0.2.0
```

## Support

For issues or feature requests:

1. Check `solo help [command]` for command-specific help
2. Review logs: `solo logs --tenant=TENANT_ID`
3. Check system health: `solo health --json`
4. File an issue with: `solo version` output and error details

## Next Steps (v0.3.0)

- Secrets management (get, set, delete)
- Log viewing and tailing
- Bulk operations
- Shell completion
- Configuration file support
- Service templates
