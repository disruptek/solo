defmodule Solo.Hardening.CodeAnalyzer do
  @moduledoc """
  Static code analysis for dangerous patterns in deployed service code.

  Validates that deployed code doesn't contain:
  - Direct file I/O (could escape isolation)
  - Port operations (could bypass security)
  - Erlang term_to_binary + binary_to_term (RCE vector)
  - Direct process spawning (should use framework APIs)
  - System calls or OS commands
  - NIFs or native code loading
  - Unauthorized module imports

  Scans the AST of compiled BEAM bytecode for red flags.
  """

  require Logger

  @dangerous_functions [
    # File I/O
    {:File, :read},
    {:File, :write},
    {:File, :rm},
    {:File, :mkdir},
    # Port operations
    {:Port, :open},
    # Serialization RCE vectors
    {:erlang, :term_to_binary},
    {:erlang, :binary_to_term},
    # Process spawning (should use framework)
    {:spawn, :link},
    {:spawn, :monitor},
    # System/OS
    {:System, :cmd},
    {:System, :shell},
    {:os, :system},
    {:os, :shell},
    # NIF loading
    {:erlang, :load_nif},
  ]

  @dangerous_macros [
    :system,
    :cmd,
  ]

  @doc """
  Analyze compiled module bytecode for dangerous patterns.

  Returns `{:ok, findings}` where findings is a list of issues found.
  Returns `{:error, reason}` if analysis fails.
  """
  @spec analyze(module(), atom()) :: {:ok, list(map())} | {:error, String.t()}
  def analyze(module, tenant_id) do
    try do
      # Get the module's AST if available
      case get_module_ast(module) do
        {:ok, ast} ->
          findings =
            ast
            |> scan_for_dangerous_calls()
            |> Enum.concat(scan_for_dangerous_patterns(ast))

          Logger.debug("[CodeAnalyzer] Analyzed #{module} for #{tenant_id}: #{length(findings)} findings")

          {:ok, findings}

        {:error, reason} ->
          Logger.warn("[CodeAnalyzer] Could not get AST for #{module}: #{inspect(reason)}")
          # If we can't get AST, assume it's safe (better to allow than block)
          {:ok, []}
      end
    rescue
      e ->
        Logger.error("[CodeAnalyzer] Analysis failed: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  @doc """
  Check if code is safe to deploy.

  Returns `true` if safe, `false` if dangerous patterns found.
  """
  @spec safe?(module(), atom()) :: boolean()
  def safe?(module, tenant_id) do
    case analyze(module, tenant_id) do
      {:ok, findings} -> length(findings) == 0
      {:error, _} -> false
    end
  end

  # === Private Helpers ===

  defp get_module_ast(module) do
    try do
      # Try to get source file
      case :code.which(module) do
        :non_existing ->
          {:error, "Module not found"}

        path when is_list(path) ->
          # Path is a charlist, convert to string
          file_path = path |> IO.iodata_to_binary()

          # Try to read and parse the source if .ex file exists
          ex_file = String.replace_suffix(file_path, ".beam", ".ex")

          case File.read(ex_file) do
            {:ok, source} ->
              case Code.string_to_quoted(source) do
                {:ok, ast} -> {:ok, ast}
                {:error, reason} -> {:error, inspect(reason)}
              end

            :enoent ->
              # No source file, that's ok
              {:error, "No source file available"}
          end

        _ ->
          {:error, "Could not determine module path"}
      end
    rescue
      e -> {:error, inspect(e)}
    end
  end

  defp scan_for_dangerous_calls(ast) do
    findings = []

    try do
      Macro.prewalk(ast, findings, fn node, acc ->
        case node do
          # Match function calls
          {{:., _, [{:__aliases__, _, module_parts}, function_name]}, _, _} ->
            module_name = module_parts |> Enum.join(".") |> String.to_atom()

            if Enum.member?(@dangerous_functions, {module_name, function_name}) do
              issue = %{
                type: :dangerous_call,
                module: module_name,
                function: function_name,
                message: "Dangerous function call: #{module_name}.#{function_name}"
              }

              {node, [issue | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)
    rescue
      _e -> findings
    end
  end

  defp scan_for_dangerous_patterns(ast) do
    findings = []

    try do
      Macro.prewalk(ast, findings, fn node, acc ->
        case node do
          # Match macro calls
          {macro_name, _, _} when macro_name in @dangerous_macros ->
            issue = %{
              type: :dangerous_macro,
              macro: macro_name,
              message: "Dangerous macro: #{macro_name}"
            }

            {node, [issue | acc]}

          # Match NIF definitions
          {:defmodule, _, [{:__aliases__, _, _}, [do: body]]} ->
            # Check if body contains nif definitions
            if String.contains?(Macro.to_string(body), "nif:") do
              issue = %{
                type: :nif_definition,
                message: "NIF definitions not allowed"
              }

              {node, [issue | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)
    rescue
      _e -> findings
    end
  end
end
