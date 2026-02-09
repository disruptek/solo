defmodule Solo.Deployment.DeployerTest do
  use ExUnit.Case

  setup do
    # EventStore, Registry, and Deployer are already started by the application
    :ok
  end

  describe "deploy/1" do
    test "deploys Elixir source code and starts the service" do
      last_id = Solo.EventStore.last_id()

      source = ~S"""
      defmodule MyService do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        def init(opts), do: {:ok, opts}

        def ping(pid), do: GenServer.call(pid, :ping)

        def handle_call(:ping, _from, state) do
          {:reply, :pong, state}
        end
      end
      """

      {:ok, pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_1",
          service_id: "test_service",
          code: source,
          format: :elixir_source
        })

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify event was emitted
      Process.sleep(100)
      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      deploy_events = Enum.filter(events, &(&1.event_type == :service_deployed))
      assert length(deploy_events) >= 1

      # Cleanup
      Solo.Deployment.Deployer.kill("agent_1", "test_service")
    end

    test "rejects unsupported format" do
      {:error, reason} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_1",
          service_id: "test_service",
          code: "defmodule X do end",
          format: :beam_bytecode
        })

      assert String.contains?(reason, "Unsupported format")
    end

    test "returns error for invalid source code" do
      {:error, reason} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_1",
          service_id: "bad_service",
          code: "this is not valid elixir",
          format: :elixir_source
        })

      assert is_binary(reason)
    end

    test "returns error if service doesn't export start_link/1" do
      source = ~S"""
      defmodule BadService do
        def init, do: :ok
      end
      """

      {:error, reason} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_1",
          service_id: "bad_service",
          code: source,
          format: :elixir_source
        })

      assert String.contains?(reason, "start_link/1")
    end
  end

  describe "kill/2" do
    test "kills a running service" do
      last_id = Solo.EventStore.last_id()

      source = ~S"""
      defmodule MyService do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """

      {:ok, pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_2",
          service_id: "service_to_kill",
          code: source,
          format: :elixir_source
        })

      assert Process.alive?(pid)

      :ok = Solo.Deployment.Deployer.kill("agent_2", "service_to_kill")

      # Give it time to die
      Process.sleep(100)
      assert not Process.alive?(pid)

      # Verify kill event was emitted
      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      kill_events = Enum.filter(events, &(&1.event_type == :service_killed))
      assert length(kill_events) >= 1
    end

    test "returns error when killing non-existent service" do
      {:error, :not_found} = Solo.Deployment.Deployer.kill("agent_2", "nonexistent_service")
    end
  end

  describe "status/2" do
    test "returns process info for a running service" do
      source = ~S"""
      defmodule MyService do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """

      {:ok, pid} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_3",
          service_id: "status_test",
          code: source,
          format: :elixir_source
        })

      status = Solo.Deployment.Deployer.status("agent_3", "status_test")

      assert status.pid == pid
      assert status.service_id == "status_test"
      assert status.tenant_id == "agent_3"
      assert status.alive == true
      assert is_list(status.info)

      Solo.Deployment.Deployer.kill("agent_3", "status_test")
    end

    test "returns error for non-existent service" do
      {:error, :not_found} = Solo.Deployment.Deployer.status("agent_3", "nonexistent")
    end
  end

  describe "list/1" do
    test "lists all services for a tenant" do
      source = ~S"""
      defmodule MyService do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """

      {:ok, pid1} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_4",
          service_id: "service_1",
          code: source,
          format: :elixir_source
        })

      {:ok, pid2} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "agent_4",
          service_id: "service_2",
          code: source,
          format: :elixir_source
        })

      services = Solo.Deployment.Deployer.list("agent_4")

      assert length(services) == 2

      service_ids = Enum.map(services, &elem(&1, 0))
      assert "service_1" in service_ids
      assert "service_2" in service_ids

      # Cleanup
      Solo.Deployment.Deployer.kill("agent_4", "service_1")
      Solo.Deployment.Deployer.kill("agent_4", "service_2")
    end

    test "lists empty for tenant with no services" do
      services = Solo.Deployment.Deployer.list("nonexistent_tenant")
      assert services == []
    end
  end

  describe "tenant isolation" do
    test "services from different tenants are isolated" do
      source = ~S"""
      defmodule MyService do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """

      {:ok, _pid1} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "tenant_a",
          service_id: "shared_name",
          code: source,
          format: :elixir_source
        })

      {:ok, _pid2} =
        Solo.Deployment.Deployer.deploy(%{
          tenant_id: "tenant_b",
          service_id: "shared_name",
          code: source,
          format: :elixir_source
        })

      services_a = Solo.Deployment.Deployer.list("tenant_a")
      services_b = Solo.Deployment.Deployer.list("tenant_b")

      assert length(services_a) == 1
      assert length(services_b) == 1

      # Kill one service shouldn't affect the other
      Solo.Deployment.Deployer.kill("tenant_a", "shared_name")
      assert Solo.Deployment.Deployer.list("tenant_a") == []
      assert length(Solo.Deployment.Deployer.list("tenant_b")) == 1

      Solo.Deployment.Deployer.kill("tenant_b", "shared_name")
    end
  end
end
