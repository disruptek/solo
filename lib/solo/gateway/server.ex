defmodule Solo.Gateway.Server do
  @moduledoc """
  gRPC service handler for Solo kernel RPC methods.

  Maps gRPC requests to backend Solo functions:
  - Deploy/Kill/Status/List - managed by Solo.Deployment.Deployer
  - Watch - streams events from Solo.EventStore
  - Shutdown - graceful kernel shutdown
  """

  use GRPC.Server, service: Solo.V1.SoloKernel.Service

  require Logger

  alias GRPC.Stream

  alias Solo.V1.{
    DeployRequest,
    DeployResponse,
    StatusRequest,
    StatusResponse,
    KillRequest,
    KillResponse,
    ListRequest,
    ListResponse,
    Event,
    ShutdownRequest,
    ShutdownResponse,
    RegisterServiceRequest,
    RegisterServiceResponse,
    DiscoverServiceRequest,
    DiscoverServiceResponse,
    DiscoveredService,
    GetServicesRequest,
    GetServicesResponse
  }

  # === RPC Handlers ===

  @doc """
  Deploy a new service from source code.
  """
  def deploy(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %DeployRequest{} = req ->
      tenant_id = extract_tenant_from_context(stream)
      Logger.info("[Gateway] Deploy request: #{tenant_id}/#{req.service_id}")

      case Solo.Deployment.Deployer.deploy(%{
             tenant_id: tenant_id,
             service_id: req.service_id,
             code: req.code,
             format: :elixir_source
           }) do
        {:ok, _pid} ->
          Logger.info("[Gateway] Deploy success: #{tenant_id}/#{req.service_id}")

          %DeployResponse{
            service_id: req.service_id,
            status: "ok",
            error: ""
          }

        {:error, reason} ->
          Logger.warning(
            "[Gateway] Deploy failed: #{tenant_id}/#{req.service_id} - #{inspect(reason)}"
          )

          %DeployResponse{
            service_id: req.service_id,
            status: "error",
            error: to_string(reason)
          }
      end
    end)
    |> Stream.run()
  end

  @doc """
  Get the status of a running service.
  """
  def status(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %StatusRequest{} = req ->
      tenant_id = extract_tenant_from_context(stream)
      Logger.info("[Gateway] Status request: #{tenant_id}/#{req.service_id}")

      case Solo.Deployment.Deployer.status(tenant_id, req.service_id) do
        status when is_map(status) ->
          Logger.info("[Gateway] Status found: #{tenant_id}/#{req.service_id}")

          %StatusResponse{
            service_id: req.service_id,
            alive: status.alive,
            memory_bytes: extract_memory(status.info),
            message_queue_len: extract_message_queue_len(status.info),
            reductions: extract_reductions(status.info)
          }

        {:error, :not_found} ->
          Logger.warning("[Gateway] Service not found: #{tenant_id}/#{req.service_id}")

          raise GRPC.RPCError.exception(
                  status: :not_found,
                  message: "Service not found"
                )
      end
    end)
    |> Stream.run()
  end

  @doc """
  Kill a running service.
  """
  def kill(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %KillRequest{} = req ->
      tenant_id = extract_tenant_from_context(stream)
      Logger.info("[Gateway] Kill request: #{tenant_id}/#{req.service_id}")

      timeout_ms = if req.timeout_ms > 0, do: req.timeout_ms, else: 5000
      opts = [timeout: timeout_ms, force: req.force]

      case Solo.Deployment.Deployer.kill(tenant_id, req.service_id, opts) do
        :ok ->
          Logger.info("[Gateway] Kill success: #{tenant_id}/#{req.service_id}")

          %KillResponse{
            service_id: req.service_id,
            status: "ok",
            error: ""
          }

        {:error, reason} ->
          Logger.warning(
            "[Gateway] Kill failed: #{tenant_id}/#{req.service_id} - #{inspect(reason)}"
          )

          %KillResponse{
            service_id: req.service_id,
            status: "error",
            error: to_string(reason)
          }
      end
    end)
    |> Stream.run()
  end

  @doc """
  List all services for the authenticated tenant.
  """
  def list(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %ListRequest{} = _req ->
      tenant_id = extract_tenant_from_context(stream)
      Logger.info("[Gateway] List request for tenant: #{tenant_id}")

      services = Solo.Deployment.Deployer.list(tenant_id)

      service_infos =
        Enum.map(services, fn {service_id, _pid} ->
          # Determine if service is alive
          case Solo.Deployment.Deployer.status(tenant_id, service_id) do
            status when is_map(status) ->
              %Solo.V1.ServiceInfo{
                service_id: service_id,
                alive: status.alive
              }

            {:error, _} ->
              %Solo.V1.ServiceInfo{
                service_id: service_id,
                alive: false
              }
          end
        end)

      Logger.info("[Gateway] Listing #{Enum.count(service_infos)} services for #{tenant_id}")

      %ListResponse{
        services: service_infos
      }
    end)
    |> Stream.run()
  end

  @doc """
  Watch events in real-time (server-side streaming).
  """
  def watch(request, stream) do
    tenant_id = extract_tenant_from_context(stream)
    Logger.info("[Gateway] Watch request: #{tenant_id}, service_id: #{request.service_id}")

    # Create an event stream from the event store
    event_stream = create_event_stream(tenant_id, request.service_id, request.include_logs)

    event_stream
    |> Stream.from()
    |> Stream.map(fn event ->
      convert_event_to_proto(event)
    end)
    |> Stream.run_with(stream)
  end

  @doc """
  Graceful shutdown of Solo kernel.
  """
  def shutdown(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %ShutdownRequest{} = req ->
      grace_period_ms = if req.grace_period_ms > 0, do: req.grace_period_ms, else: 5000
      Logger.info("[Gateway] Shutdown request with grace period: #{grace_period_ms}ms")

      # Schedule shutdown after grace period
      Task.start(fn ->
        Process.sleep(grace_period_ms)
        Logger.info("[Gateway] Graceful shutdown initiated")
        System.halt(0)
      end)

      %ShutdownResponse{
        status: "ok",
        message: "Shutdown initiated"
      }
    end)
    |> Stream.run()
  end

  @doc """
  Register a service for discovery.
  """
  def register_service(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %Solo.V1.RegisterServiceRequest{} = req ->
      tenant_id = extract_tenant_from_context(stream)
      Logger.info("[Gateway] Register service: #{tenant_id}/#{req.service_id}")

      metadata = Map.new(req.metadata)

      case Solo.ServiceRegistry.register(
             tenant_id,
             req.service_id,
             req.service_name,
             req.version,
             metadata,
             req.ttl_seconds
           ) do
        {:ok, handle} ->
          Logger.info("[Gateway] Service registered with handle: #{handle}")

          %RegisterServiceResponse{
            registered: true,
            service_handle: handle,
            error: ""
          }

        {:error, reason} ->
          Logger.warning("[Gateway] Registration failed: #{inspect(reason)}")

          %RegisterServiceResponse{
            registered: false,
            service_handle: "",
            error: to_string(reason)
          }
      end
    end)
    |> Stream.run()
  end

  @doc """
  Discover services by name.
  """
  def discover_service(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %Solo.V1.DiscoverServiceRequest{} = req ->
      tenant_id = extract_tenant_from_context(stream)
      filters = Map.new(req.filters)
      Logger.info("[Gateway] Discover service: #{req.service_name} for #{tenant_id}")

      {:ok, services} = Solo.ServiceRegistry.discover(tenant_id, req.service_name, filters)

      discovered =
        Enum.map(services, fn service ->
          %DiscoveredService{
            service_id: service.service_id,
            service_handle: service.handle,
            service_name: service.service_name,
            version: service.version,
            alive: service_alive?(tenant_id, service.service_id),
            metadata: service.metadata
          }
        end)

      %DiscoverServiceResponse{
        services: discovered
      }
    end)
    |> Stream.run()
  end

  @doc """
  Get all services for a tenant.
  """
  def get_services(request, stream) do
    request
    |> Stream.unary(materializer: stream)
    |> Stream.map(fn %Solo.V1.GetServicesRequest{} = req ->
      tenant_id = extract_tenant_from_context(stream)
      service_name = if req.service_name == "", do: nil, else: req.service_name
      Logger.info("[Gateway] Get services for #{tenant_id}")

      {:ok, services} = Solo.ServiceRegistry.list_services(tenant_id, service_name)

      discovered =
        Enum.map(services, fn service ->
          %DiscoveredService{
            service_id: service.service_id,
            service_handle: service.handle,
            service_name: service.service_name,
            version: service.version,
            alive: service_alive?(tenant_id, service.service_id),
            metadata: service.metadata
          }
        end)

      %GetServicesResponse{
        services: discovered,
        total_count: Enum.count(discovered)
      }
    end)
    |> Stream.run()
  end

  # === Private Helpers ===

  defp extract_tenant_from_context(_stream) do
    # Try to get tenant from gRPC metadata or client certificate
    # For now, use a default tenant
    # In production, this would extract from the client certificate CN/SAN
    "default_tenant"
  end

  defp create_event_stream(tenant_id, service_id, include_logs) do
    since_id = 0

    # Get events from the event store
    events =
      if service_id == "" or service_id == nil do
        # Stream all events for the tenant
        Solo.EventStore.stream(tenant_id: tenant_id, since_id: since_id)
      else
        # Stream events for a specific service
        Solo.EventStore.stream(tenant_id: tenant_id, service_id: service_id, since_id: since_id)
      end

    # Filter events if needed
    if include_logs do
      events
    else
      # Filter out verbose logging events
      Stream.filter(events, fn event ->
        event.event_type not in [:service_log, :metric_recorded]
      end)
    end
  end

  defp convert_event_to_proto(event) do
    %Event{
      id: event.id,
      timestamp: event.timestamp_ms,
      event_type: to_string(event.event_type),
      subject: event.subject,
      payload:
        Jason.encode!(event.payload)
        |> to_string()
        |> String.to_charlist()
        |> :binary.list_to_bin(),
      causation_id: event.causation_id || 0
    }
  end

  # === Process Info Extractors ===

  defp extract_memory(info) when is_map(info) do
    case info do
      %{memory: memory} -> memory
      _ -> 0
    end
  end

  defp extract_memory(_), do: 0

  defp extract_message_queue_len(info) when is_map(info) do
    case info do
      %{message_queue_len: len} -> len
      _ -> 0
    end
  end

  defp extract_message_queue_len(_), do: 0

  defp extract_reductions(info) when is_map(info) do
    case info do
      %{reductions: reductions} -> reductions
      _ -> 0
    end
  end

  defp extract_reductions(_), do: 0

  defp service_alive?(tenant_id, service_id) do
    case Solo.Deployment.Deployer.status(tenant_id, service_id) do
      status when is_map(status) -> status.alive
      {:error, _} -> false
    end
  end
end
