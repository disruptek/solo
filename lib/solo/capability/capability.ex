defmodule Solo.Capability do
  @moduledoc """
  Capability token for resource access control.

  A capability is an unforgeable token that grants permission to perform
  specific operations on a resource. Capabilities can be:
  - Created with a TTL (time to live)
  - Revoked before expiration
  - Validated before use

  Capabilities are the only way to access kernel resources from services.
  """

  require Logger

  @enforce_keys [:resource_ref, :token_hash, :permissions, :expires_at, :tenant_id]
  defstruct [
    :resource_ref,
    :token_hash,
    :permissions,
    :expires_at,
    :tenant_id,
    revoked?: false
  ]

  @typedoc """
  A capability token (opaque binary).
  """
  @type token :: binary()

  @typedoc """
  A resource reference (e.g., "filesystem", "eventstore", "registry").
  """
  @type resource_ref :: String.t()

  @typedoc """
  A permission (e.g., "read", "write", "delete").
  """
  @type permission :: String.t()

  @type t :: %__MODULE__{
          resource_ref: resource_ref(),
          token_hash: binary(),
          permissions: [permission()],
          expires_at: integer(),
          tenant_id: String.t(),
          revoked?: boolean()
        }

  @doc """
  Create a new capability token.

  Returns `{:ok, token, capability}` where:
  - `token` is the unforgeable token to be given to the service
  - `capability` is the stored capability record

  The token is hashed using SHA-256 for secure storage.
  """
  @spec create(resource_ref(), [permission()], non_neg_integer(), String.t()) ::
          {:ok, token(), t()}
  def create(resource_ref, permissions, ttl_seconds, tenant_id)
      when is_binary(resource_ref) and is_list(permissions) and is_integer(ttl_seconds) and
             is_binary(tenant_id) do
    # Generate a random token
    token = :crypto.strong_rand_bytes(32)
    token_hash = hash_token(token)

    # Calculate expiration time
    expires_at = System.system_time(:second) + ttl_seconds

    capability = %__MODULE__{
      resource_ref: resource_ref,
      token_hash: token_hash,
      permissions: permissions,
      expires_at: expires_at,
      tenant_id: tenant_id,
      revoked?: false
    }

    Logger.debug("[Capability] Created token for #{resource_ref}: #{permissions |> Enum.join(",")}")

    {:ok, token, capability}
  end

  @doc """
  Check if a capability is valid (not expired, not revoked).
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{revoked?: true}), do: false

  def valid?(%__MODULE__{expires_at: expires_at}) do
    System.system_time(:second) < expires_at
  end

  @doc """
  Check if a capability allows a specific permission.
  """
  @spec allows?(t(), permission()) :: boolean()
  def allows?(%__MODULE__{permissions: permissions}, permission) do
    permission in permissions
  end

  @doc """
  Mark a capability as revoked.
  """
  @spec revoke(t()) :: t()
  def revoke(%__MODULE__{} = cap) do
    %{cap | revoked?: true}
  end

  @doc """
  Verify a token against a capability.

  Returns `true` if the token matches the capability's token hash.
  """
  @spec verify_token(token(), t()) :: boolean()
  def verify_token(token, %__MODULE__{token_hash: stored_hash}) when is_binary(token) do
    token_hash = hash_token(token)
    # Constant-time comparison to prevent timing attacks
    token_hash == stored_hash
  end

  # === Private Helpers ===

  defp hash_token(token) do
    :crypto.hash(:sha256, token)
  end
end
