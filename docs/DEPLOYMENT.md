# Solo Deployment Guide

This guide covers deploying Solo in production environments.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [Running Solo](#running-solo)
5. [Monitoring](#monitoring)
6. [Security](#security)
7. [Troubleshooting](#troubleshooting)

## Prerequisites

### System Requirements

- **OS**: Linux (tested on Ubuntu 20.04+), macOS, or other Unix-like
- **Memory**: Minimum 1 GB (512 MB kernel + per-tenant limits)
- **CPU**: 2+ cores recommended
- **Network**: For gRPC communication (port 50051)

### Software Requirements

```bash
# Erlang 28.3.1
erlc --version
# Eshell V28.3.1

# Elixir 1.19.5
elixir --version
# Elixir 1.19.5

# Mix (comes with Elixir)
mix --version
# Mix 1.19.5
```

### Installation Tools

Using ASDF (recommended):

```bash
# Install asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf

# Install Erlang
asdf plugin-add erlang
asdf install erlang 28.3.1

# Install Elixir
asdf plugin-add elixir
asdf install elixir 1.19.5

# Set local versions
cd /path/to/solo
echo "erlang 28.3.1" > .tool-versions
echo "elixir 1.19.5" >> .tool-versions
asdf install
```

## Installation

### 1. Clone Repository

```bash
git clone https://github.com/disruptek/solo.git
cd solo
```

### 2. Set Environment

```bash
export PATH="$HOME/.asdf/installs/erlang/28.3.1/bin:$HOME/.asdf/installs/elixir/1.19.5/bin:$PATH"
```

Or add to `~/.bashrc` or `~/.zshrc`:

```bash
if [ -d "$HOME/.asdf" ]; then
  . "$HOME/.asdf/asdf.sh"
  . "$HOME/.asdf/completions/asdf.bash"
fi
```

### 3. Install Dependencies

```bash
mix deps.get
mix deps.compile
```

### 4. Verify Installation

```bash
mix test --seed 0
# Should see: "Finished in X seconds, 113 tests, 0 failures"
```

## Configuration

### Environment Variables

```bash
# Resource Limits (per tenant)
export SOLO_MEMORY_LIMIT=512        # MB per tenant (default)
export SOLO_PROCESS_LIMIT=100       # processes per tenant (default)
export SOLO_MAILBOX_LIMIT=10000     # messages per process (default)

# gRPC Configuration
export SOLO_GRPC_PORT=50051         # gRPC server port (default)
export SOLO_GRPC_HOST=0.0.0.0       # gRPC bind address (default)

# Storage
export SOLO_DATA_DIR=./data         # Event store and vault path (default)

# Telemetry
export SOLO_TELEMETRY_HANDLERS=logger  # Handlers to attach

# Logging
export SOLO_LOG_LEVEL=info          # :debug, :info, :warn, :error
```

### Configuration File (Optional)

Create `config/prod.exs`:

```elixir
import Config

config :solo,
  memory_limit: 512,
  process_limit: 100,
  mailbox_limit: 10000

config :grpc,
  port: 50051,
  host: "0.0.0.0"

config :logger,
  level: :info,
  backends: [{:console, []}, {File.Stream, "logs/solo.log"}]
```

### Systemd Service (Optional)

Create `/etc/systemd/system/solo.service`:

```ini
[Unit]
Description=Solo Operating System
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=solo
WorkingDirectory=/opt/solo
ExecStart=/usr/bin/env bash -c 'export PATH="$HOME/.asdf/installs/erlang/28.3.1/bin:$HOME/.asdf/installs/elixir/1.19.5/bin:$PATH" && iex -S mix start'
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable solo
sudo systemctl start solo
sudo systemctl status solo
```

## Running Solo

### Development Mode

```bash
iex -S mix

iex> # System is running, try deploying a service
iex> {:ok, pid} = Solo.Deployment.Deployer.deploy(%{
...>   tenant_id: "test_tenant",
...>   service_id: "test_service",
...>   code: "defmodule Test do end",
...>   format: :elixir_source
...> })
```

### Production Mode (Release)

```bash
# Build release
mix release

# Run release
_build/prod/rel/solo/bin/solo start

# Connect to running node
_build/prod/rel/solo/bin/solo remote
```

### Docker

Create `Dockerfile`:

```dockerfile
FROM erlang:28.3.1

RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/asdf-vm/asdf/archive/v0.13.1.tar.gz | tar xz -C /opt && \
    mv /opt/asdf-* /opt/asdf

RUN /opt/asdf/bin/asdf plugin-add elixir || true && \
    /opt/asdf/bin/asdf install elixir 1.19.5

ENV PATH="/opt/asdf/shims:/opt/asdf/bin:$PATH"

WORKDIR /app
COPY . .

RUN mix deps.get && mix deps.compile

EXPOSE 50051

CMD ["iex", "-S", "mix", "start"]
```

Build and run:

```bash
docker build -t solo .
docker run -p 50051:50051 solo
```

## Monitoring

### Health Check

```bash
# Check EventStore is running
curl http://localhost:50051/health || echo "gRPC, not HTTP"

# Or via IEx
iex> {:ok, _} = Solo.EventStore.last_id()
```

### Event Stream Monitoring

```bash
iex> events = Solo.EventStore.stream()
iex> Stream.each(events, &IO.inspect/1) |> Stream.run()
```

### Service Status

```bash
iex> {:ok, services} = Solo.Deployment.Deployer.list("tenant_1")
iex> IO.inspect(services)

iex> {:ok, status} = Solo.Deployment.Deployer.status("tenant_1", "service_1")
iex> IO.inspect(status)
```

### System Audit

```bash
iex> {:ok, audit} = Solo.Hardening.audit()
iex> IO.inspect(audit)
```

### Logs

```bash
# View system logs
journalctl -u solo -f

# Or file logs
tail -f logs/solo.log
```

## Security

### mTLS Configuration

Solo comes with mTLS support. For production:

```elixir
# Generate certificates
{:ok, ca_cert, ca_key} = Solo.Security.MTLS.generate_ca()
{:ok, server_cert, server_key} = Solo.Security.MTLS.generate_cert(:server, ca_cert, ca_key)
{:ok, client_cert, client_key} = Solo.Security.MTLS.generate_cert(:client, ca_cert, ca_key)

# Store certificates securely
# Use environment variables or secrets manager
System.put_env("SOLO_CA_CERT", Base.encode64(ca_cert))
System.put_env("SOLO_SERVER_CERT", Base.encode64(server_cert))
System.put_env("SOLO_SERVER_KEY", Base.encode64(server_key))
```

### Code Validation

All deployed code is validated for dangerous patterns:

```elixir
# Check if code is safe
{:ok, report} = Solo.Hardening.validate(tenant_id, service_id, code)

# If report.status == :unsafe, don't deploy
```

### Capability Token Management

```bash
# Tokens are managed by Capability.Manager
# Tokens have TTL (time-to-live)
# Always revoke tokens when done

iex> {:ok, token} = Solo.Capability.Manager.grant("tenant_1", :admin, %{})
iex> :ok = Solo.Capability.Manager.revoke(token)
```

### Resource Limits

Configure per-tenant limits:

```bash
export SOLO_MEMORY_LIMIT=512        # MB per tenant
export SOLO_PROCESS_LIMIT=100       # processes per tenant
export SOLO_MAILBOX_LIMIT=10000     # messages per process
```

## Troubleshooting

### Issue: Port Already in Use

```bash
# Find process using port 50051
lsof -i :50051

# Kill the process
kill -9 <PID>

# Or use different port
export SOLO_GRPC_PORT=50052
```

### Issue: Out of Memory

```bash
# Check memory usage
iex> :erlang.memory() |> IO.inspect()

# Reduce per-tenant limit
export SOLO_MEMORY_LIMIT=256

# Or increase system memory
```

### Issue: Service Not Found

```bash
# Verify service was deployed
iex> {:ok, services} = Solo.Deployment.Deployer.list("tenant_1")
iex> IO.inspect(services)

# Check events
iex> events = Solo.EventStore.filter(event_type: :service_deployed)
iex> Enum.each(events, &IO.inspect/1)
```

### Issue: Capability Verification Fails

```bash
# Verify token is active
iex> {:ok, metadata} = Solo.Capability.Manager.verify(tenant_id, token, permission)

# Check if token was revoked
iex> {:error, "Token revoked"} = Solo.Capability.Manager.verify(tenant_id, token, permission)

# Grant new token
iex> {:ok, new_token} = Solo.Capability.Manager.grant(tenant_id, permission, %{})
```

### Issue: Hot Swap Fails

```bash
# Check service is running
iex> {:ok, status} = Solo.Deployment.Deployer.status(tenant_id, service_id)

# Verify code is valid
iex> {:ok, report} = Solo.Hardening.validate(tenant_id, service_id, new_code)
iex> IO.inspect(report)

# Use simple replace if hot swap continues to fail
iex> {:ok, new_pid} = Solo.HotSwap.replace(tenant_id, service_id, new_code)
```

### Issue: Event Store Growing Too Large

```bash
# Check event count
iex> last_id = Solo.EventStore.last_id()
iex> IO.inspect(last_id)

# Backup events
iex> events = Solo.EventStore.stream()
iex> # Export to file or external storage

# In production, implement event archival
# See: ARCHITECTURE.md
```

### Debug Mode

Enable verbose logging:

```bash
export SOLO_LOG_LEVEL=debug
iex -S mix

# Or in code
Logger.configure(level: :debug)
```

## Performance Tuning

### Erlang VM Tuning

```bash
# Increase process limit
export ERL_FLAGS="+P 262144"

# Increase file descriptors
ulimit -n 65536

# Set scheduler threads
export ERL_FLAGS="+S 4:4"  # 4 schedulers
```

### Resource Limits Tuning

```bash
# For many small services
export SOLO_MEMORY_LIMIT=256
export SOLO_PROCESS_LIMIT=50

# For few large services
export SOLO_MEMORY_LIMIT=1024
export SOLO_PROCESS_LIMIT=500
```

### Circuit Breaker Tuning

The circuit breaker automatically handles failing services:

```elixir
# Default: opens after 5 consecutive failures
# Adjust in code if needed
Solo.Backpressure.CircuitBreaker.call({tenant_id, service_id}, fun)
```

## Backup & Recovery

### Backup Event Store

```bash
# Copy data directory
cp -r ./data ./data.backup.$(date +%s)

# Or use S3
aws s3 sync ./data s3://backup-bucket/solo-events/
```

### Restore Event Store

```bash
# Stop Solo
systemctl stop solo

# Restore from backup
rm -rf ./data
cp -r ./data.backup.123456 ./data

# Start Solo
systemctl start solo
```

### Event Replay

```bash
iex> # Replay events from a specific point
iex> events = Solo.EventStore.stream(since_id: 1000)
iex> Enum.each(events, &IO.inspect/1)
```

## Scaling

### Horizontal Scaling

Solo is designed as a single-node system. For horizontal scaling:

1. Run multiple Solo instances
2. Load balance across them (e.g., nginx)
3. Use external EventStore (Phase 9+)
4. Implement distributed locking (Phase 9+)

### Vertical Scaling

Increase resources for a single node:

```bash
# Increase memory limit
export SOLO_MEMORY_LIMIT=2048

# Increase process limits
export SOLO_PROCESS_LIMIT=500
export SOLO_MAILBOX_LIMIT=50000

# Tune Erlang VM
export ERL_FLAGS="+P 262144 +S 8:8"
```

## Summary

Solo is ready for production deployment with:
- ✅ 113 passing tests
- ✅ Multi-tenant isolation
- ✅ Secure by default
- ✅ Comprehensive monitoring
- ✅ Hot code replacement
- ✅ Complete audit trail

Next steps:
1. Test in staging environment
2. Configure for your infrastructure
3. Set up monitoring and alerting
4. Plan backup and recovery procedures
5. Deploy to production

For more information, see:
- [README.md](README.md) - Overview and usage
- [ARCHITECTURE.md](ARCHITECTURE.md) - System design
- [API.md](API.md) - API reference
