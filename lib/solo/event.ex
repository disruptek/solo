defmodule Solo.Event do
  @moduledoc """
  The fundamental event struct for Solo.

  Events are the lingua franca of the whole system. Every significant state change
  emits an event into the append-only EventStore.

  Fields:
  - `id`: Monotonically increasing sequence number (not UUID, ordered and gap-free)
  - `timestamp`: Erlang monotonic time (highest precision)
  - `wall_clock`: DateTime in UTC
  - `tenant_id`: Which tenant created this event (nil for system events)
  - `event_type`: Atom describing what happened (e.g., :service_deployed)
  - `subject`: What the event is about (e.g., tenant_id or {tenant_id, service_id})
  - `payload`: Map of event-specific data
  - `causation_id`: ID of the event that caused this one (for tracing)
  """

  @enforce_keys [:id, :timestamp, :wall_clock, :event_type, :subject, :payload]
  defstruct [
    :id,
    :timestamp,
    :wall_clock,
    :tenant_id,
    :event_type,
    :subject,
    :payload,
    :causation_id
  ]

  @typedoc """
  Event type identifier - describes what happened.
  """
  @type event_type ::
          :system_started
          | :service_deployed
          | :service_started
          | :service_killed
          | :service_crashed
          | :atom_usage_high
          | :resource_violation
          | :capability_granted
          | :capability_revoked
          | :capability_denied
          | :hot_swap_started
          | :hot_swap_succeeded
          | :hot_swap_rolled_back
          | :secret_stored
          | :secret_accessed
          | :secret_access_denied

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          timestamp: integer(),
          wall_clock: DateTime.t(),
          tenant_id: String.t() | nil,
          event_type: event_type(),
          subject: any(),
          payload: map(),
          causation_id: non_neg_integer() | nil
        }

  @doc """
  Create a new event with monotonic timestamp and wall clock.
  """
  @spec new(event_type(), any(), map(), non_neg_integer(), String.t() | nil, non_neg_integer() | nil) :: t()
  def new(event_type, subject, payload, id, tenant_id \\ nil, causation_id \\ nil) do
    %__MODULE__{
      id: id,
      timestamp: System.monotonic_time(),
      wall_clock: DateTime.utc_now(),
      tenant_id: tenant_id,
      event_type: event_type,
      subject: subject,
      payload: payload,
      causation_id: causation_id
    }
  end
end
