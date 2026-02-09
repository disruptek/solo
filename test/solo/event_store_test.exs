defmodule Solo.EventStoreTest do
  use ExUnit.Case

  setup do
    # EventStore is already started by the application
    # We just verify it's available
    :ok
  end

  describe "EventStore basics" do
    test "application boots successfully" do
      # The EventStore should be available
      assert is_pid(Process.whereis(Solo.EventStore))
    end

    test "emit adds an event" do
      last_id = Solo.EventStore.last_id()
      Solo.EventStore.emit(:test, "subject", %{msg: "hello"})
      Process.sleep(100)  # Give cast time to be processed

      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      assert length(events) >= 1

      event = Enum.find(events, &(&1.subject == "subject"))
      assert event.event_type == :test
      assert event.subject == "subject"
      assert event.payload == %{msg: "hello"}
    end

    test "stream filters by tenant_id" do
      last_id = Solo.EventStore.last_id()
      tenant_id = "test_tenant_#{System.unique_integer()}"
      
      Solo.EventStore.emit(:test, "subject1", %{}, tenant_id)
      Solo.EventStore.emit(:test, "subject2", %{}, "other_tenant")
      Solo.EventStore.emit(:test, "subject3", %{}, tenant_id)
      Process.sleep(100)

      events = Solo.EventStore.stream(tenant_id: tenant_id, since_id: last_id) |> Enum.to_list()
      assert length(events) == 2

      subject_ids = Enum.map(events, & &1.subject)
      assert subject_ids == ["subject1", "subject3"]
    end

    test "last_id returns current sequence number" do
      last_id_1 = Solo.EventStore.last_id()

      Solo.EventStore.emit(:test, "subject", %{})
      Process.sleep(100)

      last_id_2 = Solo.EventStore.last_id()
      assert last_id_2 > last_id_1
    end

    test "events have monotonic IDs" do
      last_id = Solo.EventStore.last_id()
      
      Solo.EventStore.emit(:test, "s1", %{})
      Solo.EventStore.emit(:test, "s2", %{})
      Solo.EventStore.emit(:test, "s3", %{})
      Process.sleep(100)

      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      ids = Enum.map(events, & &1.id)
      # Verify IDs are increasing
      assert ids == Enum.sort(ids)
    end

    test "events have timestamps" do
      last_id = Solo.EventStore.last_id()
      Solo.EventStore.emit(:test, "subject", %{})
      Process.sleep(100)

      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      assert length(events) >= 1

      event = Enum.find(events, &(&1.subject == "subject"))
      # Just verify the timestamp is a reasonable integer (monotonic time)
      assert is_integer(event.timestamp)
      assert event.timestamp != 0
    end

    test "events have wall clock" do
      last_id = Solo.EventStore.last_id()
      Solo.EventStore.emit(:test, "subject", %{})
      Process.sleep(100)

      events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      assert length(events) >= 1

      event = Enum.find(events, &(&1.subject == "subject"))
      assert event.wall_clock != nil
      assert is_struct(event.wall_clock, DateTime)
    end
  end

  describe "causation_id tracking" do
    test "events can reference their causation" do
      last_id = Solo.EventStore.last_id()
      
      Solo.EventStore.emit(:test, "first", %{})
      Process.sleep(50)

      first_events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      first_event = Enum.find(first_events, &(&1.subject == "first"))
      first_event_id = first_event.id

      Solo.EventStore.emit(:test, "second", %{}, nil, first_event_id)
      Process.sleep(50)

      all_events = Solo.EventStore.stream(since_id: last_id) |> Enum.to_list()
      second_event = Enum.find(all_events, &(&1.subject == "second"))

      assert second_event.causation_id == first_event_id
    end
  end
end
