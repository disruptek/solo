defmodule Solo.EventStore do
  @moduledoc """
  Append-only, replayable event log backed by CubDB.

  The EventStore is the single source of truth for all state changes in the system.
  Events are written asynchronously via cast to ensure audit logging never blocks
  the critical path.

  Writes to disk via CubDB and can be replayed by streaming all events with filters
  for tenant, service, or time range.
  """

  use GenServer

  require Logger

  @doc """
  Start the EventStore GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Emit an event into the store (asynchronous via cast).

  Returns :ok immediately; the event will be written to disk shortly.
  """
  @spec emit(Solo.Event.event_type(), any(), map(), String.t() | nil, non_neg_integer() | nil) :: :ok
  def emit(event_type, subject, payload \\ %{}, tenant_id \\ nil, causation_id \\ nil) do
    GenServer.cast(__MODULE__, {:emit, event_type, subject, payload, tenant_id, causation_id})
  end

  @doc """
  Stream events with optional filters.

  Options:
  - `tenant_id`: Filter by tenant
  - `service_id`: Filter by service (requires tenant_id)
  - `since_id`: Start from this event ID (exclusive)
  - `limit`: Maximum number of events to return

  Returns an Enumerable of Solo.Event structs.
  """
  @spec stream(Keyword.t()) :: Enumerable.t()
  def stream(opts \\ []) do
    GenServer.call(__MODULE__, {:stream, opts})
  end

  @doc """
  Get the current sequence number (latest event ID).
  """
  @spec last_id() :: non_neg_integer()
  def last_id do
    GenServer.call(__MODULE__, :last_id)
  end

  @doc """
  Filter events by type, tenant, or service.

  Options:
  - `event_type`: Match specific event type
  - `tenant_id`: Filter by tenant
  - `service_id`: Filter by service (requires tenant_id)

  Returns a list of matching Solo.Event structs.
  """
  @spec filter(Keyword.t()) :: list(Solo.Event.t())
  def filter(opts \\ []) do
    event_type = Keyword.get(opts, :event_type)
    tenant_id = Keyword.get(opts, :tenant_id)
    service_id = Keyword.get(opts, :service_id)

    stream(tenant_id: tenant_id, service_id: service_id)
    |> Stream.filter(fn event ->
      if event_type, do: event.event_type == event_type, else: true
    end)
    |> Enum.to_list()
  end

  @doc """
  Reset the event store for testing (drops all events).
  """
  @spec reset!() :: :ok
  def reset! do
    GenServer.call(__MODULE__, :reset)
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, "./data/events")
    {:ok, db} = CubDB.start_link(db_path)

    # Initialize the counter if it doesn't exist
    next_id =
      case CubDB.get(db, :next_id) do
        nil ->
          CubDB.put(db, :next_id, 1)
          1

        id ->
          id
      end

    Logger.info("[EventStore] Started with next_id=#{next_id}")

    {:ok, %{db: db, next_id: next_id}}
  end

  @impl GenServer
  def handle_cast({:emit, event_type, subject, payload, tenant_id, causation_id}, state) do
    %{db: db, next_id: next_id} = state

    event = Solo.Event.new(event_type, subject, payload, next_id, tenant_id, causation_id)

    # Store the event by ID and increment the counter
    CubDB.put(db, {:event, next_id}, event)
    CubDB.put(db, :next_id, next_id + 1)

    Logger.debug("[EventStore] Emitted event #{next_id}: #{event_type}")

    {:noreply, %{state | next_id: next_id + 1}}
  end

  @impl GenServer
  def handle_call(:last_id, _from, state) do
    {:reply, state.next_id - 1, state}
  end

  def handle_call(:reset, _from, %{db: db} = state) do
    # Clear all events and reset counter
    # Get all keys and delete them
    keys = CubDB.select(db, []) |> Enum.map(&elem(&1, 0)) |> Enum.to_list()
    Enum.each(keys, &CubDB.delete(db, &1))
    CubDB.put(db, :next_id, 1)
    {:reply, :ok, %{state | next_id: 1}}
  end

  def handle_call({:stream, opts}, _from, %{db: db} = state) do
    tenant_id = Keyword.get(opts, :tenant_id)
    service_id = Keyword.get(opts, :service_id)
    since_id = Keyword.get(opts, :since_id, 0)
    limit = Keyword.get(opts, :limit, :infinity)

    stream =
      Stream.unfold(since_id + 1, fn id ->
        case CubDB.get(db, {:event, id}) do
          nil -> nil
          event -> {event, id + 1}
        end
      end)
      |> Stream.filter(fn event ->
        # Apply tenant filter
        if tenant_id, do: event.tenant_id == tenant_id, else: true
      end)
      |> Stream.filter(fn event ->
        # Apply service filter (if service_id is specified, subject must match {tenant_id, service_id})
        if service_id do
          event.subject == {tenant_id, service_id}
        else
          true
        end
      end)
      |> then(fn s ->
        # Only apply take if limit is not infinity
        if limit == :infinity, do: s, else: Stream.take(s, limit)
      end)

    {:reply, stream, state}
  end
end
