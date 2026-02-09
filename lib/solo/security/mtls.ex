defmodule Solo.Security.MTLS do
  @moduledoc """
  Certificate management for mutual TLS.

  On first boot, generates:
  - CA certificate and key
  - Server certificate signed by CA
  - Both stored in ./data/certs/ (configurable)

  Client certificates are generated on demand via mix task:
  `mix solo.gen_cert <agent_id>`
  """

  require Logger

  @default_cert_dir "./data/certs"
  @ca_key_file "ca-key.pem"
  @ca_cert_file "ca.pem"
  @server_key_file "server-key.pem"
  @server_cert_file "server.pem"

  @doc """
  Get or create CA and server certificates.

  Returns `{ca_cert, server_cert, server_key}` as PEM binaries.
  """
  @spec get_or_create_certs(String.t()) ::
          {:ok, {binary(), binary(), binary()}} | {:error, String.t()}
  def get_or_create_certs(cert_dir \\ @default_cert_dir) do
    with :ok <- ensure_cert_dir(cert_dir),
         {:ok, ca_cert, ca_key} <- get_or_create_ca(cert_dir),
         {:ok, server_cert, server_key} <- get_or_create_server_cert(cert_dir, ca_cert, ca_key) do
      {:ok, {ca_cert, server_cert, server_key}}
    end
  end

  @doc """
  Generate a client certificate for an agent.

  Returns `{cert, key}` as PEM binaries.
  """
  @spec generate_client_cert(String.t(), String.t()) :: {:ok, {binary(), binary()}} | {:error, String.t()}
  def generate_client_cert(agent_id, cert_dir \\ @default_cert_dir) do
    try do
      with {:ok, ca_cert_pem, ca_key_pem} <- get_or_create_ca(cert_dir) do
        ca_cert = X509.Certificate.from_pem!(ca_cert_pem)
        ca_key = X509.PrivateKey.from_pem!(ca_key_pem)

        # Create client private key
        client_key = X509.PrivateKey.new_ec(:secp256r1)
        client_key_pem = X509.PrivateKey.to_pem(client_key)

        # Create client certificate
        client_cert =
          X509.Certificate.new(
            client_key,
            "/CN=#{agent_id}",
            ca_cert,
            ca_key
          )

        client_cert_pem = X509.Certificate.to_pem(client_cert)

        {:ok, {client_cert_pem, client_key_pem}}
      end
    rescue
      e ->
        {:error, "Failed to create client certificate: #{Exception.message(e)}"}
    end
  end

  @doc """
  Extract tenant_id from a client certificate CN.
  """
  @spec extract_tenant_id(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_tenant_id(cert_pem) when is_binary(cert_pem) do
    try do
      cert = X509.Certificate.from_pem!(cert_pem)
      {:ok, cert_subject} = X509.Certificate.subject(cert)

      case X509.RDNSequence.get_attr(cert_subject, :commonName) do
        [tenant_id] -> {:ok, tenant_id}
        _ -> {:error, "Could not extract tenant_id from certificate"}
      end
    rescue
      e ->
        {:error, "Failed to parse certificate: #{Exception.message(e)}"}
    end
  end

  # === Private Helpers ===

  defp ensure_cert_dir(cert_dir) do
    case File.mkdir_p(cert_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not create cert directory: #{inspect(reason)}"}
    end
  end

  defp get_or_create_ca(cert_dir) do
    ca_key_path = Path.join(cert_dir, @ca_key_file)
    ca_cert_path = Path.join(cert_dir, @ca_cert_file)

    case {File.read(ca_key_path), File.read(ca_cert_path)} do
      {{:ok, ca_key_pem}, {:ok, ca_cert_pem}} ->
        Logger.debug("[MTLS] Using existing CA certificate")
        {:ok, ca_cert_pem, ca_key_pem}

      _ ->
        Logger.info("[MTLS] Generating new CA certificate")
        create_ca(ca_key_path, ca_cert_path)
    end
  end

  defp create_ca(key_path, cert_path) do
    try do
      # Generate CA key
      ca_key = X509.PrivateKey.new_ec(:secp256r1)
      ca_key_pem = X509.PrivateKey.to_pem(ca_key)

      # Create CA certificate (self-signed)
      ca_cert =
        X509.Certificate.self_signed(
          ca_key,
          "/C=US/ST=State/L=City/O=Solo/CN=Solo-CA"
        )

      ca_cert_pem = X509.Certificate.to_pem(ca_cert)

      # Write to disk
      with :ok <- File.write(key_path, ca_key_pem),
           :ok <- File.write(cert_path, ca_cert_pem) do
        {:ok, ca_cert_pem, ca_key_pem}
      else
        {:error, reason} -> {:error, "Could not write CA certificate: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Failed to create CA certificate: #{Exception.message(e)}"}
    end
  end

  defp get_or_create_server_cert(cert_dir, ca_cert_pem, ca_key_pem) do
    server_key_path = Path.join(cert_dir, @server_key_file)
    server_cert_path = Path.join(cert_dir, @server_cert_file)

    case {File.read(server_key_path), File.read(server_cert_path)} do
      {{:ok, server_key_pem}, {:ok, server_cert_pem}} ->
        Logger.debug("[MTLS] Using existing server certificate")
        {:ok, server_cert_pem, server_key_pem}

      _ ->
        Logger.info("[MTLS] Generating new server certificate")
        create_server_cert(server_key_path, server_cert_path, ca_cert_pem, ca_key_pem)
    end
  end

  defp create_server_cert(key_path, cert_path, ca_cert_pem, ca_key_pem) do
    try do
      ca_cert = X509.Certificate.from_pem!(ca_cert_pem)
      ca_key = X509.PrivateKey.from_pem!(ca_key_pem)

      # Generate server key
      server_key = X509.PrivateKey.new_ec(:secp256r1)
      server_key_pem = X509.PrivateKey.to_pem(server_key)

      # Create server certificate
      server_cert =
        X509.Certificate.new(
          server_key,
          "/C=US/ST=State/L=City/O=Solo/CN=localhost",
          ca_cert,
          ca_key
        )

      server_cert_pem = X509.Certificate.to_pem(server_cert)

      # Write to disk
      with :ok <- File.write(key_path, server_key_pem),
           :ok <- File.write(cert_path, server_cert_pem) do
        {:ok, server_cert_pem, server_key_pem}
      else
        {:error, reason} -> {:error, "Could not write server certificate: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Failed to create server certificate: #{Exception.message(e)}"}
    end
  end
end
