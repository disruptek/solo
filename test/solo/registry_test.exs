defmodule Solo.RegistryTest do
  use ExUnit.Case

  setup do
    # Registry is already started by the application
    :ok
  end

  describe "Registry operations" do
    test "register a service" do
      pid = self()
      {:ok, returned_pid} = Solo.Registry.register("tenant_1", "service_1", pid)
      assert returned_pid == pid
    end

    test "lookup a registered service" do
      pid = self()
      Solo.Registry.register("tenant_1", "service_1", pid)

      result = Solo.Registry.lookup("tenant_1", "service_1")
      assert [{^pid, _}] = result
    end

    test "lookup returns empty list for unregistered service" do
      result = Solo.Registry.lookup("tenant_1", "service_1")
      assert result == []
    end

    test "cannot register the same service twice" do
      pid1 = self()

      {:ok, ^pid1} = Solo.Registry.register("tenant_1", "service_1", pid1)
      
      pid2 = spawn(fn -> :timer.sleep(:infinity) end)
      {:error, {:already_registered, existing}} = Solo.Registry.register("tenant_1", "service_1", pid2)
      assert existing == pid1

      # Cleanup
      Process.exit(pid2, :kill)
    end

    test "list_for_tenant returns all services for a tenant" do
      pid1 = spawn(fn -> :timer.sleep(:infinity) end)
      pid2 = spawn(fn -> :timer.sleep(:infinity) end)
      pid3 = spawn(fn -> :timer.sleep(:infinity) end)

      Solo.Registry.register("tenant_1", "service_1", pid1)
      Solo.Registry.register("tenant_1", "service_2", pid2)
      Solo.Registry.register("tenant_2", "service_1", pid3)

      services = Solo.Registry.list_for_tenant("tenant_1")
      assert length(services) == 2

      service_ids = Enum.map(services, &elem(&1, 0))
      assert "service_1" in service_ids
      assert "service_2" in service_ids

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.exit(pid3, :kill)
    end

    test "unregister removes a service" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      Solo.Registry.register("tenant_1", "service_1", pid)

      Solo.Registry.unregister("tenant_1", "service_1")
      result = Solo.Registry.lookup("tenant_1", "service_1")
      assert result == []

      # Cleanup
      Process.exit(pid, :kill)
    end

    test "list_for_tenant returns empty for tenant with no services" do
      services = Solo.Registry.list_for_tenant("nonexistent_tenant")
      assert services == []
    end
  end
end
