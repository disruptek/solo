defmodule Solo.Deployment.CompilerTest do
  use ExUnit.Case

  describe "Compiler.compile" do
    test "compiles valid Elixir source" do
      source = """
      defmodule MyService do
        def hello, do: "world"
      end
      """

      {:ok, modules} = Solo.Deployment.Compiler.compile("tenant_1", "service_1", source)

      assert is_list(modules)
      assert length(modules) >= 1
    end

    test "returns error for invalid Elixir source" do
      source = """
      defmodule MyService do
        def hello do
          # Missing 'do' block
      end
      """

      {:error, reason} = Solo.Deployment.Compiler.compile("tenant_1", "service_1", source)
      assert is_binary(reason)
    end

    test "namespaces the module correctly" do
      tenant_id = "agent_1"
      service_id = "my_service"

      namespace = Solo.Deployment.Compiler.namespace(tenant_id, service_id)
      assert String.starts_with?(namespace, "Solo.User_agent_1")
      assert String.contains?(namespace, "my_service")
    end

    test "sanitizes tenant and service IDs" do
      # Test with special characters
      namespace = Solo.Deployment.Compiler.namespace("agent-1", "my-service")
      assert namespace == "Solo.User_agent_1_my_service"
    end

    test "compiled module is executable" do
      source = """
      def ping, do: :pong
      def add(a, b), do: a + b
      """

      {:ok, modules} = Solo.Deployment.Compiler.compile("tenant_1", "service_1", source)
      assert length(modules) >= 1

      # The module should be available
      module = modules |> Enum.map(&elem(&1, 0)) |> hd()
      assert module.ping() == :pong
      assert module.add(2, 3) == 5
    end
  end
end
