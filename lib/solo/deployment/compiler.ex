defmodule Solo.Deployment.Compiler do
  @moduledoc """
  Compiles Elixir source code into BEAM bytecode.

  User modules are namespaced under `Solo.User.{tenant_id}.{service_id}` to prevent
  collisions between services from different tenants or different services from the same tenant.

  No static analysis is performed at this stage (that's Phase 8: CodeAnalyzer).
  """

  require Logger

  @doc """
  Compile Elixir source code for a service.

  Returns `{:ok, [{module, bytecode}]}` on success, or `{:error, reason}` on failure.

  The source code is wrapped in a namespace to prevent collisions.
  """
  @spec compile(String.t(), String.t(), String.t()) ::
          {:ok, [{module(), binary()}]} | {:error, String.t()}
  def compile(tenant_id, service_id, source_code)
      when is_binary(tenant_id) and is_binary(service_id) and is_binary(source_code) do
    namespace = namespace(tenant_id, service_id)

    # Wrap the user's code in the namespace
    wrapped_code = wrap_code(namespace, source_code)

    Logger.debug(
      "[Compiler] Compiling #{service_id} for tenant #{tenant_id} (namespace: #{namespace})"
    )

    try do
      # Code.compile_string/2 returns a list of {module, bytecode} tuples
      modules = Code.compile_string(wrapped_code, "#{namespace}.ex")
      Logger.info("[Compiler] Successfully compiled #{service_id} with #{length(modules)} module(s)")
      {:ok, modules}
    rescue
      e ->
        error_msg = Exception.message(e)
        Logger.error("[Compiler] Compilation error: #{error_msg}")
        {:error, error_msg}
    end
  end

  @doc """
  Get the namespace module name for a service.
  """
  @spec namespace(String.t(), String.t()) :: String.t()
  def namespace(tenant_id, service_id) do
    # Use flat namespace with underscores to separate
    # Solo.User.tenant_id_service_id
    tenant_safe = sanitize(tenant_id)
    service_safe = sanitize(service_id)
    "Solo.User#{tenant_safe}#{service_safe}"
  end

  # === Private Helpers ===

  defp wrap_code(namespace, source_code) do
    """
    defmodule #{namespace} do
      require Logger

      # User's code starts here
      #{source_code}
    end
    """
  end

  defp sanitize(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.replace(~r/^_+|_+$/, "")
    |> (fn s -> "_" <> s end).()
  end


end
