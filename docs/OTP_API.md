# Solo OTP API Reference

Complete Elixir/Erlang API for Solo v0.2.0. All APIs are designed for use from Elixir code.

**See Also:**
- For HTTP/REST API: [REST_API.md](REST_API.md)
- For CLI usage: [../CLI_GUIDE.md](../CLI_GUIDE.md)

---

## Core Modules

### Solo.Deployment.Deployer

Service deployment and lifecycle management.

#### Deploy Service

```elixir
Solo.Deployment.Deployer.deploy(spec :: map()) 
  :: {:ok, pid()} | {:error, String.t()}
```

**Parameters:**
- `tenant_id` (required) - Tenant identifier
- `service_id` (required) - Service identifier (unique per tenant)
- `code` (required) - Elixir source code as string
- `format` (required) - Currently only `:elixir_source` supported
- `restart_limits` (optional) - Resource limits map

**Example:**
```elixir
{:ok, pid} = Solo.Deployment.Deployer.deploy(%{
  tenant_id: "agent_1",
  service_id: "my_service",
  code: """
  defmodule MyService do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, %{})
    def init(state), do: {:ok, state}
  end
  """,
  format: :elixir_source,
  restart_limits: %{max_restarts: 5, max_seconds: 60}
})
```

#### Get Service Status

```elixir
Solo.Deployment.Deployer.status(tenant_id :: String.t(), service_id :: String.t())
  :: map() | {:error, :not_found}
```

**Returns:**
```elixir
%{
  pid: #PID<0.123.0>,
  alive: true,
  memory_bytes: 1048576,
  message_queue_len: 5,
  reductions: 500000,
  info: %{...}  # Raw process info
}
```

**Example:**
```elixir
{:ok, status} = Solo.Deployment.Deployer.status("agent_1", "my_service")
IO.puts("Memory: #{status.memory_bytes} bytes")
```

#### Kill Service

```elixir
Solo.Deployment.Deployer.kill(tenant_id :: String.t(), service_id :: String.t(), 
                              opts :: Keyword.t())
  :: :ok | {:error, String.t()}
```

**Options:**
- `timeout` (ms, default: 5000) - Graceful shutdown timeout
- `force` (boolean, default: false) - Force kill immediately

**Example:**
```elixir
:ok = Solo.Deployment.Deployer.kill("agent_1", "my_service", timeout: 10000)
```

#### List Services

```elixir
Solo.Deployment.Deployer.list(tenant_id :: String.t())
  :: [{service_id :: String.t(), pid()}]
```

**Example:**
```elixir
services = Solo.Deployment.Deployer.list("agent_1")
Enum.each(services, fn {id, pid} ->
  IO.puts("Service: #{id} (PID: #{inspect(pid)})")
end)
```

---

### Solo.EventStore

Append-only event log for audit trail and replay.

#### Emit Event

```elixir
Solo.EventStore.emit(event_type :: atom(), subject :: any(), 
                     payload :: map(), tenant_id :: String.t() | nil,
                     causation_id :: non_neg_integer() | nil)
  :: :ok
```

**Event Types:**
- `:service_deployed` - Service deployment successful
- `:service_deployment_failed` - Deployment failed
- `:service_killed` - Service terminated
- `:service_crashed` - Service crashed unexpectedly
- `:capability_granted` - Capability token issued
- `:capability_verified` - Capability verified
- `:capability_revoked` - Capability revoked
- `:secret_stored` - Secret encrypted and stored
- `:secret_accessed` - Secret retrieved
- `:hot_swap_started` - Hot swap initiated
- `:hot_swap_succeeded` - Hot swap completed
- `:hot_swap_rolled_back` - Hot swap rolled back

**Example:**
```elixir
Solo.EventStore.emit(:service_deployed, {tenant_id, service_id}, %{
  tenant_id: tenant_id,
  service_id: service_id,
  timestamp: DateTime.utc_now()
})
```

#### Stream Events

```elixir
Solo.EventStore.stream(opts :: Keyword.t())
  :: Stream.t(Solo.Event.t())
```

**Options:**
- `tenant_id` (String) - Filter by tenant
- `service_id` (String) - Filter by service (requires tenant_id)
- `since_id` (non_neg_integer) - Events after this ID (exclusive)
- `limit` (non_neg_integer) - Maximum events to return

**Example:**
```elixir
events = Solo.EventStore.stream(tenant_id: "agent_1", limit: 100)
  |> Enum.to_list()
```

#### Filter Events

```elixir
Solo.EventStore.filter(opts :: Keyword.t())
  :: [Solo.Event.t()]
```

**Options:**
- `event_type` (atom) - Filter by type
- `tenant_id` (String) - Filter by tenant
- `service_id` (String) - Filter by service

**Example:**
```elixir
deployments = Solo.EventStore.filter(
  event_type: :service_deployed,
  tenant_id: "agent_1"
)
```

#### Get Event by ID

```elixir
Solo.EventStore.last_id()
  :: non_neg_integer()
```

**Example:**
```elixir
last = Solo.EventStore.last_id()
IO.puts("Latest event ID: #{last}")
```

---

### Solo.Capability.Manager

Token-based access control and permission management.

#### Grant Capability

```elixir
Solo.Capability.Manager.grant(tenant_id :: String.t(), 
                              permission :: atom(),
                              metadata :: map())
  :: {:ok, token :: String.t()} | {:error, String.t()}
```

**Permissions:** Can be any atom, examples:
- `:read` - Read permission
- `:write` - Write permission
- `:admin` - Administrative access
- `:deploy` - Service deployment

**Example:**
```elixir
{:ok, token} = Solo.Capability.Manager.grant("agent_1", :deploy, %{
  service_id: "my_service"
})
IO.puts("Token: #{token}")
```

#### Verify Capability

```elixir
Solo.Capability.Manager.verify(tenant_id :: String.t(),
                               token :: String.t(),
                               permission :: atom())
  :: {:ok, metadata :: map()} | {:error, String.t()}
```

**Example:**
```elixir
case Solo.Capability.Manager.verify("agent_1", token, :deploy) do
  {:ok, metadata} -> IO.puts("Permission granted")
  {:error, reason} -> IO.puts("Permission denied: #{reason}")
end
```

#### Revoke Capability

```elixir
Solo.Capability.Manager.revoke(token :: String.t())
  :: :ok | {:error, String.t()}
```

**Example:**
```elixir
:ok = Solo.Capability.Manager.revoke(token)
```

#### List Capabilities

```elixir
Solo.Capability.Manager.list(tenant_id :: String.t())
  :: [%{token: String.t(), permission: atom(), expires_at: DateTime.t()}]
```

---

### Solo.Vault

Encrypted secret storage and management.

#### Store Secret

```elixir
Solo.Vault.store(tenant_id :: String.t(),
                 secret_name :: String.t(),
                 secret_value :: String.t(),
                 key :: String.t(),
                 opts :: Keyword.t())
  :: :ok | {:error, String.t()}
```

**Parameters:**
- `key` - Master key for this secret (used for encryption)

**Example:**
```elixir
:ok = Solo.Vault.store("agent_1", "DB_PASSWORD", "secret123", "master_key")
```

#### Retrieve Secret

```elixir
Solo.Vault.retrieve(tenant_id :: String.t(),
                    secret_name :: String.t(),
                    key :: String.t())
  :: {:ok, String.t()} | {:error, String.t()}
```

**Example:**
```elixir
{:ok, value} = Solo.Vault.retrieve("agent_1", "DB_PASSWORD", "master_key")
IO.puts("Secret: #{value}")
```

#### List Secrets

```elixir
Solo.Vault.list_secrets(tenant_id :: String.t())
  :: {:ok, [String.t()]} | {:error, String.t()}
```

**Example:**
```elixir
{:ok, secrets} = Solo.Vault.list_secrets("agent_1")
IO.inspect(secrets)  # ["DB_PASSWORD", "API_KEY", ...]
```

#### Revoke Secret

```elixir
Solo.Vault.revoke(tenant_id :: String.t(),
                  secret_name :: String.t())
  :: :ok | {:error, String.t()}
```

**Example:**
```elixir
:ok = Solo.Vault.revoke("agent_1", "DB_PASSWORD")
```

---

### Solo.HotSwap

Live code replacement and hot-swapping.

#### Hot Swap Service

```elixir
Solo.HotSwap.swap(tenant_id :: String.t(),
                  service_id :: String.t(),
                  new_code :: String.t(),
                  opts :: Keyword.t())
  :: :ok | {:error, String.t()}
```

**Options:**
- `rollback_window_ms` (ms, default: 30000) - Auto-rollback if crashes within window

**Example:**
```elixir
:ok = Solo.HotSwap.swap("agent_1", "my_service", new_code, 
                        rollback_window_ms: 60000)
```

#### Replace Service

```elixir
Solo.HotSwap.replace(tenant_id :: String.t(),
                     service_id :: String.t(),
                     new_code :: String.t())
  :: {:ok, pid()} | {:error, String.t()}
```

**Example:**
```elixir
{:ok, new_pid} = Solo.HotSwap.replace("agent_1", "my_service", new_code)
```

---

### Solo.Hardening

Static code analysis and security validation.

#### Validate Code

```elixir
Solo.Hardening.validate(tenant_id :: String.t(),
                        service_id :: String.t(),
                        code :: String.t())
  :: {:ok, report :: map()} | {:error, String.t()}
```

**Validation checks:**
- File I/O operations (File.read, File.write)
- Port operations (Port.open)
- Serialization RCE (term_to_binary)
- System calls (System.cmd)
- NIF loading (erlang:load_nif)
- Unauthorized imports

**Example:**
```elixir
{:ok, report} = Solo.Hardening.validate("agent_1", "my_service", code)
case report.status do
  :safe -> IO.puts("Code is safe")
  :unsafe -> IO.puts("Code has violations: #{report.violations}")
end
```

#### System Audit

```elixir
Solo.Hardening.audit()
  :: {:ok, report :: map()} | {:error, String.t()}
```

**Example:**
```elixir
{:ok, report} = Solo.Hardening.audit()
IO.inspect(report)  # %{status: :healthy, components: [...]}
```

---

### Solo.ServiceRegistry

Service discovery and registration.

#### Register Service

```elixir
Solo.ServiceRegistry.register_service(tenant_id :: String.t(),
                                      service_id :: String.t(),
                                      metadata :: map())
  :: {:ok, String.t()} | {:error, String.t()}
```

**Example:**
```elixir
{:ok, ref} = Solo.ServiceRegistry.register_service("agent_1", "api_server", %{
  host: "localhost",
  port: 5000,
  version: "1.0.0"
})
```

#### Discover Services

```elixir
Solo.ServiceRegistry.discover_services(filters :: map())
  :: {:ok, [map()]} | {:error, String.t()}
```

**Example:**
```elixir
{:ok, services} = Solo.ServiceRegistry.discover_services(%{
  tenant_id: "agent_1",
  service_id: "api_server"
})
```

#### Get Services

```elixir
Solo.ServiceRegistry.get_services(tenant_id :: String.t())
  :: {:ok, [map()]} | {:error, String.t()}
```

---

### Solo.Registry

Service lookup and resolution.

#### Register Service

```elixir
Solo.Registry.register(tenant_id :: String.t(),
                       service_id :: String.t(),
                       pid :: pid())
  :: :ok | {:error, :already_registered}
```

#### Lookup Service

```elixir
Solo.Registry.lookup(tenant_id :: String.t(),
                     service_id :: String.t())
  :: {:ok, pid()} | {:error, :not_found}
```

#### List Services

```elixir
Solo.Registry.list(tenant_id :: String.t())
  :: [{service_id :: String.t(), pid()}]
```

---

### Solo.Telemetry

Observability, metrics, and event measurement.

#### Emit Event

```elixir
Solo.Telemetry.emit(domain :: atom(),
                    action :: atom(),
                    measurements :: map(),
                    metadata :: map())
  :: :ok
```

**Example:**
```elixir
Solo.Telemetry.emit(:deployment, :deploy, %{duration_ms: 150}, %{
  service_id: "my_service",
  tenant_id: "agent_1"
})
```

#### Measure Function

```elixir
Solo.Telemetry.measure(domain :: atom(),
                       action :: atom(),
                       fun :: (() -> any()))
  :: any()
```

**Example:**
```elixir
result = Solo.Telemetry.measure(:deployment, :deploy, fn ->
  Solo.Deployment.Deployer.deploy(spec)
end)
```

---

### Solo.AtomMonitor

Runtime atom table monitoring for resource protection.

#### Get Atom Count

```elixir
Solo.AtomMonitor.get_count()
  :: non_neg_integer()
```

---

### Solo.Config

Configuration management.

#### Load Configuration

```elixir
Solo.Config.load(file_path :: String.t())
  :: {:ok, map()} | {:error, String.t()}
```

**Supported formats:** TOML, JSON

**Example:**
```elixir
{:ok, config} = Solo.Config.load("config.toml")
```

#### Get Default Configuration

```elixir
Solo.Config.default()
  :: map()
```

---

## Data Structures

### Solo.Event

Immutable event structure with metadata.

```elixir
%Solo.Event{
  id: non_neg_integer(),           # Monotonic event ID
  event_type: atom(),               # e.g., :service_deployed
  timestamp: DateTime.t(),          # When event occurred
  subject: any(),                   # What the event is about
  payload: map(),                   # Event data
  tenant_id: String.t() | nil,      # Which tenant
  causation_id: non_neg_integer()   # Which event caused this
}
```

### Service Metadata

```elixir
%{
  tenant_id: String.t(),
  service_id: String.t(),
  pid: pid(),
  alive: boolean(),
  memory_bytes: non_neg_integer(),
  message_queue_len: non_neg_integer(),
  reductions: non_neg_integer(),
  created_at: DateTime.t()
}
```

### Capability Token

```elixir
%{
  token: String.t(),               # Unforgeable token
  permission: atom(),              # Permission granted
  tenant_id: String.t(),           # Which tenant
  metadata: map(),                 # Custom metadata
  created_at: DateTime.t(),        # When granted
  expires_at: DateTime.t() | nil   # When expires
}
```

---

## Error Handling

All functions follow Erlang conventions:

```elixir
# Success
{:ok, result} = Solo.Deployment.Deployer.deploy(spec)

# Error
{:error, reason} = Solo.Deployment.Deployer.deploy(invalid_spec)

# Or direct value
status = Solo.EventStore.last_id()
```

Common error reasons:
- `:not_found` - Resource doesn't exist
- `:invalid_request` - Bad parameters
- `:permission_denied` - Capability check failed
- `:already_exists` - Resource already registered
- `:internal_error` - Server-side error

---

## Concurrency & Safety

All APIs are designed for concurrent use:

- **Processes are isolated** - Each service runs in its own GenServer
- **Tenant isolation** - Tenants cannot interfere with each other
- **Event store is append-only** - No race conditions on writes
- **Capability tokens are immutable** - Can't be modified after creation

No locks needed for normal operations.

---

## Performance Characteristics

Typical operation times:

| Operation | Time |
|-----------|------|
| Deploy service | 100-500ms |
| Get status | <10ms |
| Emit event | <5ms |
| Verify capability | <2ms |
| List services (100) | <50ms |
| Store secret | <50ms |
| Retrieve secret | <10ms |

See DEPLOYMENT.md for production tuning.

---

## See Also

- [REST API Documentation](REST_API.md)
- [Architecture Guide](ARCHITECTURE.md)
- [Deployment Guide](DEPLOYMENT.md)
- [CLI Guide](../CLI_GUIDE.md)
