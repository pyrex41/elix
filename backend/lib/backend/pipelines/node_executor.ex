defmodule Backend.Pipelines.NodeExecutor do
  @moduledoc """
  Protocol for executing different types of nodes in a pipeline.

  Each node type must implement this protocol to define how it processes
  input data and produces output.
  """

  @doc """
  Executes the node logic with the given inputs.

  ## Parameters
    - node: The Node resource with type and config
    - inputs: Map of input data from previous nodes
    - context: Execution context (pipeline_run_id, etc.)

  ## Returns
    - {:ok, output_data, metadata} on success
    - {:error, reason} on failure
  """
  @callback execute(node :: map(), inputs :: map(), context :: map()) ::
              {:ok, map(), map()} | {:error, String.t()}

  @doc """
  Validates the node configuration for this type.

  ## Returns
    - :ok if valid
    - {:error, message} if invalid
  """
  @callback validate_config(node :: map()) :: :ok | {:error, String.t()}

  @doc """
  Routes execution to the appropriate node type implementation.
  """
  def execute(node, inputs, context) do
    case node.type do
      :text ->
        Backend.Pipelines.NodeTypes.TextNode.execute(node, inputs, context)

      :http_request ->
        Backend.Pipelines.NodeTypes.HttpNode.execute(node, inputs, context)

      :llm ->
        Backend.Pipelines.NodeTypes.LlmNode.execute(node, inputs, context)

      _ ->
        {:error, "Unknown node type: #{node.type}"}
    end
  end

  @doc """
  Validates configuration for a node type.
  """
  def validate_config(node) do
    case node.type do
      :text ->
        Backend.Pipelines.NodeTypes.TextNode.validate_config(node)

      :http_request ->
        Backend.Pipelines.NodeTypes.HttpNode.validate_config(node)

      :llm ->
        Backend.Pipelines.NodeTypes.LlmNode.validate_config(node)

      _ ->
        {:error, "Unknown node type: #{node.type}"}
    end
  end
end
