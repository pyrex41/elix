defmodule Backend.Pipelines.Domain do
  @moduledoc """
  The Pipelines domain for managing LLM pipeline workflows.

  This domain provides resources for building, executing, and monitoring
  node-based pipeline systems similar to Flowise/Langflow.
  """

  use Ash.Domain,
    extensions: [
      AshJsonApi.Domain
    ]

  resources do
    resource Backend.Pipelines.Resources.Pipeline
    resource Backend.Pipelines.Resources.Node
    resource Backend.Pipelines.Resources.Edge
    resource Backend.Pipelines.Resources.PipelineRun
    resource Backend.Pipelines.Resources.NodeResult
  end

  json_api do
    prefix "/api/v3"
    log_errors? true
  end
end
