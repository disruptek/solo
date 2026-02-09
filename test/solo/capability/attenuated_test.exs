defmodule Solo.Capability.AttenuatedTest do
  use ExUnit.Case

  setup do
    # Start a simple mock resource server
    {:ok, mock_pid} = MockResource.start_link()
    {:ok, mock_pid: mock_pid}
  end

  describe "Attenuated proxy" do
    test "allows permitted operations", %{mock_pid: mock_pid} do
      {:ok, proxy_pid} =
        Solo.Capability.Attenuated.start_link(
          resource_ref: "filesystem",
          allowed_operations: [:read, :stat],
          real_pid: mock_pid,
          tenant_id: "tenant_1"
        )

      # Call should succeed
      assert {:ok, :data} = GenServer.call(proxy_pid, :read)
    end

    test "blocks forbidden operations", %{mock_pid: mock_pid} do
      {:ok, proxy_pid} =
        Solo.Capability.Attenuated.start_link(
          resource_ref: "filesystem",
          allowed_operations: [:read],
          real_pid: mock_pid,
          tenant_id: "tenant_1"
        )

      # Write is not allowed
      assert {:error, :forbidden} = GenServer.call(proxy_pid, :write)
    end

    test "emits capability_denied event on forbidden operation", %{mock_pid: mock_pid} do
      last_id = Solo.EventStore.last_id()

      {:ok, proxy_pid} =
        Solo.Capability.Attenuated.start_link(
          resource_ref: "filesystem",
          allowed_operations: [:read],
          real_pid: mock_pid,
          tenant_id: "tenant_1"
        )

      GenServer.call(proxy_pid, :write)
      Process.sleep(100)

      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      deny_events = Enum.filter(events, &(&1.event_type == :capability_denied))

      assert length(deny_events) >= 1
    end

    test "blocks unknown message formats", %{mock_pid: mock_pid} do
      {:ok, proxy_pid} =
        Solo.Capability.Attenuated.start_link(
          resource_ref: "filesystem",
          allowed_operations: [:read],
          real_pid: mock_pid,
          tenant_id: "tenant_1"
        )

      assert {:error, :forbidden} = GenServer.call(proxy_pid, {:unknown, :format, :extra})
    end
  end
end

defmodule MockResource do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def init([]), do: {:ok, %{}}

  def handle_call(:read, _from, state), do: {:reply, {:ok, :data}, state}
  def handle_call(:write, _from, state), do: {:reply, {:ok, :written}, state}
  def handle_call(:stat, _from, state), do: {:reply, {:ok, :metadata}, state}
  def handle_call(msg, _from, state), do: {:reply, {:error, :unknown}, state}
end
