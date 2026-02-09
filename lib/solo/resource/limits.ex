defmodule Solo.Resource.Limits do
  @moduledoc """
  Configuration for resource limits on services.

  Defines hard limits on:
  - Memory consumption
  - Process count
  - Message queue length
  - CPU reductions (task count)

  Each limit includes an action to take when exceeded:
  - `:kill` - terminate the service immediately
  - `:throttle` - slow down message processing (for mailbox)
  - `:warn` - log a warning but continue

  Startup and shutdown timeouts prevent hanging services.
  """

  @enforce_keys []
  defstruct [
    # Memory limits
    max_memory_bytes: 50 * 1024 * 1024,  # 50 MB default
    memory_action: :warn,
    memory_warning_percent: 80,

    # Process limits
    max_processes: 1000,
    process_action: :warn,

    # Mailbox limits
    max_message_queue_len: 10_000,
    mailbox_action: :throttle,

    # Reductions (approximates CPU work)
    max_reductions: 100_000_000,
    reductions_action: :warn,

    # Timeouts
    startup_timeout_ms: 5000,
    shutdown_timeout_ms: 5000,

    # Monitoring
    check_interval_ms: 1000
  ]

  @typedoc "Action to take when limit is exceeded"
  @type action :: :kill | :throttle | :warn

  @type t :: %__MODULE__{
          max_memory_bytes: non_neg_integer(),
          memory_action: action(),
          memory_warning_percent: 0..100,
          max_processes: non_neg_integer(),
          process_action: action(),
          max_message_queue_len: non_neg_integer(),
          mailbox_action: action(),
          max_reductions: non_neg_integer(),
          reductions_action: action(),
          startup_timeout_ms: non_neg_integer(),
          shutdown_timeout_ms: non_neg_integer(),
          check_interval_ms: non_neg_integer()
        }

  @doc """
  Create resource limits with defaults.

  Options override the defaults for the fields they specify.
  """
  @spec new(Keyword.t()) :: t()
  def new(opts \\ []) do
    defaults = %__MODULE__{}
    struct(defaults, opts)
  end

  @doc """
  Validate limits are sensible.

  Returns `:ok` if valid, `{:error, reason}` if not.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = limits) do
    cond do
      limits.max_memory_bytes == 0 ->
        {:error, "max_memory_bytes must be > 0"}

      limits.max_message_queue_len == 0 ->
        {:error, "max_message_queue_len must be > 0"}

      limits.memory_warning_percent > 100 ->
        {:error, "memory_warning_percent must be <= 100"}

      limits.startup_timeout_ms == 0 ->
        {:error, "startup_timeout_ms must be > 0"}

      limits.shutdown_timeout_ms == 0 ->
        {:error, "shutdown_timeout_ms must be > 0"}

      true ->
        :ok
    end
  end

  @doc """
  Get the memory limit in bytes.
  """
  @spec memory_limit_bytes(t()) :: non_neg_integer()
  def memory_limit_bytes(%__MODULE__{max_memory_bytes: bytes}), do: bytes

  @doc """
  Get the memory warning threshold in bytes.
  """
  @spec memory_warning_bytes(t()) :: non_neg_integer()
  def memory_warning_bytes(%__MODULE__{max_memory_bytes: bytes, memory_warning_percent: percent}) do
    div(bytes * percent, 100)
  end
end
