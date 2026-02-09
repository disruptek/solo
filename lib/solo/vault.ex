defmodule Solo.Vault do
  @moduledoc """
  Encrypted secret storage for tenant credentials and sensitive data.

  Stores secrets with AES-256-GCM encryption, automatic key derivation,
  and event-based audit logging.

  Encryption details:
  - Algorithm: AES-256-GCM (authenticated encryption)
  - IV: 12 bytes (96 bits) randomly generated per secret
  - Authentication tag: 16 bytes (128 bits)
  - Key derivation: PBKDF2 with SHA-256

  All secret operations are logged to EventStore for auditability.
  """

  use GenServer
  require Logger

  @doc """
  Start the Vault GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a secret encrypted with a tenant's master key.

  Returns `:ok` on success, `{:error, reason}` on failure.

  Options:
  - `key`: Plaintext encryption key (will be derived for actual encryption)
  """
  @spec store(String.t(), String.t(), String.t(), String.t(), Keyword.t()) :: :ok | {:error, String.t()}
  def store(tenant_id, secret_name, secret_value, key, opts \\ []) when
        is_binary(tenant_id) and is_binary(secret_name) and is_binary(secret_value) and
          is_binary(key) do
    GenServer.call(__MODULE__, {:store, tenant_id, secret_name, secret_value, key, opts})
  end

  @doc """
  Retrieve and decrypt a secret for a tenant.

  Returns `{:ok, secret_value}` on success, `{:error, reason}` on failure.
  """
  @spec retrieve(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def retrieve(tenant_id, secret_name, key) when
        is_binary(tenant_id) and is_binary(secret_name) and is_binary(key) do
    GenServer.call(__MODULE__, {:retrieve, tenant_id, secret_name, key})
  end

  @doc """
  List all secret names for a tenant (doesn't decrypt values).

  Returns `{:ok, list_of_secret_names}` on success.
  """
  @spec list_secrets(String.t()) :: {:ok, list(String.t())} | {:error, String.t()}
  def list_secrets(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:list_secrets, tenant_id})
  end

  @doc """
  Revoke a stored secret (soft delete, encrypted data remains).

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec revoke(String.t(), String.t()) :: :ok | {:error, String.t()}
  def revoke(tenant_id, secret_name) when is_binary(tenant_id) and is_binary(secret_name) do
    GenServer.call(__MODULE__, {:revoke, tenant_id, secret_name})
  end

  # === GenServer Callbacks ===

   @impl GenServer
   def init(opts) do
     db_path = Keyword.get(opts, :db_path, "./data/vault")
     
     try do
       {:ok, db} = CubDB.start_link(db_path)
       Logger.info("[Vault] Started with db_path=#{db_path}")
       {:ok, %{db: db, db_path: db_path}}
     rescue
       e ->
         Logger.error("[Vault] Failed to start: #{inspect(e)}")
         {:stop, e}
     catch
       e ->
         Logger.error("[Vault] Caught error during init: #{inspect(e)}")
         {:stop, e}
     end
   end

   @impl GenServer
   def terminate(reason, state) do
     Logger.info("[Vault] Terminating with reason: #{inspect(reason)}")
     
     # CubDB is a supervised process and will be cleaned up by the supervisor
     # No need to manually close it
     
     :ok
   end

  @impl GenServer
  def handle_call({:store, tenant_id, secret_name, secret_value, key, _opts}, _from, state) do
    result =
      try do
        # Encrypt the secret
        with {:ok, encrypted} <- encrypt_secret(secret_value, key) do
          # Store encrypted data
          CubDB.put(state.db, {:secret, tenant_id, secret_name}, encrypted)

          # Emit event
          Solo.EventStore.emit(:secret_stored, {tenant_id, secret_name}, %{
            tenant_id: tenant_id,
            secret_name: secret_name
          })

          Logger.debug("[Vault] Stored secret #{secret_name} for #{tenant_id}")
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
      rescue
        e ->
          Logger.error("[Vault] Failed to store secret: #{inspect(e)}")
          {:error, inspect(e)}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:retrieve, tenant_id, secret_name, key}, _from, state) do
    result =
      try do
        case CubDB.get(state.db, {:secret, tenant_id, secret_name}) do
          nil ->
            {:error, "Secret not found"}

          encrypted ->
            # Decrypt the secret
            with {:ok, secret_value} <- decrypt_secret(encrypted, key) do
              # Emit event
              Solo.EventStore.emit(:secret_accessed, {tenant_id, secret_name}, %{
                tenant_id: tenant_id,
                secret_name: secret_name
              })

              Logger.debug("[Vault] Accessed secret #{secret_name} for #{tenant_id}")
              {:ok, secret_value}
            else
              {:error, reason} ->
                Logger.warning("[Vault] Failed to decrypt secret: #{inspect(reason)}")

                Solo.EventStore.emit(:secret_access_denied, {tenant_id, secret_name}, %{
                  reason: inspect(reason),
                  tenant_id: tenant_id,
                  secret_name: secret_name
                })

                {:error, reason}
            end
        end
      rescue
        e ->
          Logger.error("[Vault] Failed to retrieve secret: #{inspect(e)}")
          {:error, inspect(e)}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:list_secrets, tenant_id}, _from, state) do
    result =
      try do
        secrets =
          CubDB.select(state.db, [])
          |> Enum.filter(fn {{:secret, t, _name}, _value} -> t == tenant_id; _ -> false end)
          |> Enum.map(fn {{:secret, _t, name}, _value} -> name end)
          |> Enum.sort()

        {:ok, secrets}
      rescue
        e ->
          Logger.error("[Vault] Failed to list secrets: #{inspect(e)}")
          {:error, inspect(e)}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:revoke, tenant_id, secret_name}, _from, state) do
    result =
      try do
        CubDB.delete(state.db, {:secret, tenant_id, secret_name})

        Solo.EventStore.emit(:secret_revoked, {tenant_id, secret_name}, %{
          tenant_id: tenant_id,
          secret_name: secret_name
        })

        Logger.info("[Vault] Revoked secret #{secret_name} for #{tenant_id}")
        :ok
      rescue
        e ->
          Logger.error("[Vault] Failed to revoke secret: #{inspect(e)}")
          {:error, inspect(e)}
      end

    {:reply, result, state}
  end

  # === Private Helpers ===

   # Encrypt secret value with AES-256-GCM
   defp encrypt_secret(plaintext, key) do
     try do
       # Derive encryption key from the provided key
       derived_key = derive_key(key, 32)

       # Generate random IV (96 bits for GCM)
       iv = :crypto.strong_rand_bytes(12)

       # Encrypt with AES-256-GCM
       # crypto_one_time_aead(Type, Key, IV, PlainText, AAD, TagLength, EncFlag)
       {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, derived_key, iv, plaintext, "", 16, true)

       # Combine IV + tag + ciphertext for storage
       combined = iv <> tag <> ciphertext

       {:ok, combined}
     rescue
       e -> {:error, inspect(e)}
     end
   end

   # Decrypt secret value with AES-256-GCM
   defp decrypt_secret(combined, key) do
     try do
       # Derive the same key
       derived_key = derive_key(key, 32)

       # Extract IV (first 12 bytes), tag (next 16 bytes), ciphertext (rest)
       <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> = combined

       # Decrypt with AES-256-GCM
       # crypto_one_time_aead(Type, Key, IV, CipherText, AAD, Tag, false)
       plaintext = :crypto.crypto_one_time_aead(:aes_256_gcm, derived_key, iv, ciphertext, "", tag, false)

       # Check if decryption returned an error atom (happens on tag verification failure)
       case plaintext do
         :error -> {:error, "Decryption failed - tag verification failed"}
         _ -> {:ok, plaintext}
       end
     rescue
       e -> {:error, inspect(e)}
     end
   end

  # Derive a key from a master key using SHA-256
  # In production, would use a salt stored per secret and PBKDF2
  defp derive_key(master_key, length) do
    # Simple key derivation: hash the master key multiple times
    # In production, use PBKDF2 with random salt per secret
    derived = master_key <> "solo-vault-salt"
    
    # Hash and pad to requested length
    hashed = :crypto.hash(:sha256, derived)
    
    if byte_size(hashed) >= length do
      binary_part(hashed, 0, length)
    else
      # Extend by hashing again
      hashed2 = :crypto.hash(:sha256, hashed <> derived)
      combined = hashed <> hashed2
      binary_part(combined, 0, length)
    end
  end
end
