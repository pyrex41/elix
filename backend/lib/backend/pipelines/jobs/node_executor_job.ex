defmodule Backend.Pipelines.Jobs.NodeExecutorJob do
  @moduledoc """
  Oban job that executes a single node in a pipeline run.

  This job:
  1. Loads the node and its configuration
  2. Gathers input data from previous node results
  3. Executes the node using the appropriate NodeExecutor
  4. Stores the output in the NodeResult
  5. Handles errors and retries
  """

  use Oban.Worker,
    queue: :nodes,
    max_attempts: 5

  require Logger

  alias Backend.Pipelines.Resources.{Node, NodeResult, Edge, PipelineRun}
  alias Backend.Pipelines.NodeExecutor

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"pipeline_run_id" => pipeline_run_id, "node_id" => node_id},
        attempt: attempt
      }) do
    Logger.info("[NodeExecutor] Executing node #{node_id} in run #{pipeline_run_id}")

    with {:ok, node} <- load_node(node_id),
         {:ok, node_result} <- load_node_result(pipeline_run_id, node_id),
         {:ok, node_result} <- mark_running(node_result, attempt),
         {:ok, inputs} <- gather_inputs(pipeline_run_id, node_id),
         {:ok, output, metadata} <- execute_node(node, inputs, pipeline_run_id) do
      # Success! Store the output
      complete_node_result(node_result, output, metadata)
    else
      {:error, :node_not_found} ->
        Logger.error("[NodeExecutor] Node #{node_id} not found")
        {:error, :node_not_found}

      {:error, :result_not_found} ->
        Logger.error("[NodeExecutor] NodeResult not found for node #{node_id}")
        {:error, :result_not_found}

      {:error, reason} ->
        Logger.error("[NodeExecutor] Node execution failed: #{inspect(reason)}")

        # Try to load node result and mark as failed
        case load_node_result(pipeline_run_id, node_id) do
          {:ok, node_result} ->
            metadata = %{"retry_count" => attempt, "last_error" => inspect(reason)}
            fail_node_result(node_result, reason, metadata)

          _ ->
            {:error, reason}
        end
    end
  end

  # Private helpers

  defp load_node(node_id) do
    case Node.read(node_id) do
      {:ok, node} -> {:ok, node}
      {:error, _} -> {:error, :node_not_found}
    end
  end

  defp load_node_result(pipeline_run_id, node_id) do
    query =
      NodeResult
      |> Ash.Query.filter(pipeline_run_id == ^pipeline_run_id and node_id == ^node_id)

    case Ash.read(query) do
      {:ok, [result | _]} -> {:ok, result}
      {:ok, []} -> {:error, :result_not_found}
      {:error, _} -> {:error, :result_not_found}
    end
  end

  defp mark_running(node_result, attempt) do
    metadata = Map.put(node_result.metadata || %{}, "retry_count", attempt - 1)

    case NodeResult.start(node_result) do
      {:ok, updated} ->
        # Update metadata with retry count
        case Ash.Changeset.for_update(updated, :update, %{metadata: metadata})
             |> Ash.update() do
          {:ok, updated} -> {:ok, updated}
          {:error, _} -> {:ok, updated}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp gather_inputs(pipeline_run_id, node_id) do
    # Find all edges where this node is the target
    query =
      Edge
      |> Ash.Query.filter(target_node_id == ^node_id)

    case Ash.read(query) do
      {:ok, edges} ->
        # Get the source node IDs
        source_node_ids = Enum.map(edges, & &1.source_node_id)

        if length(source_node_ids) == 0 do
          # No dependencies, use pipeline run input_data
          case PipelineRun.read(pipeline_run_id) do
            {:ok, run} -> {:ok, run.input_data || %{}}
            {:error, _} -> {:ok, %{}}
          end
        else
          # Get the outputs from source nodes
          result_query =
            NodeResult
            |> Ash.Query.filter(
              pipeline_run_id == ^pipeline_run_id and node_id in ^source_node_ids
            )

          case Ash.read(result_query) do
            {:ok, source_results} ->
              # Merge all output data into a single map
              inputs =
                Enum.reduce(source_results, %{}, fn result, acc ->
                  Map.merge(acc, result.output_data || %{})
                end)

              {:ok, inputs}

            {:error, _} ->
              {:ok, %{}}
          end
        end

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp execute_node(node, inputs, pipeline_run_id) do
    context = %{
      pipeline_run_id: pipeline_run_id,
      node_id: node.id
    }

    Logger.info(
      "[NodeExecutor] Executing node type: #{node.type}, inputs: #{inspect(Map.keys(inputs))}"
    )

    NodeExecutor.execute(node, inputs, context)
  end

  defp complete_node_result(node_result, output, metadata) do
    Logger.info("[NodeExecutor] Node #{node_result.node_id} completed successfully")

    NodeResult.complete(node_result, output, metadata)
    :ok
  end

  defp fail_node_result(node_result, reason, metadata) do
    error_message =
      case reason do
        msg when is_binary(msg) -> msg
        _ -> inspect(reason)
      end

    Logger.error("[NodeExecutor] Node #{node_result.node_id} failed: #{error_message}")

    NodeResult.fail(node_result, error_message, metadata)
    {:error, reason}
  end
end
