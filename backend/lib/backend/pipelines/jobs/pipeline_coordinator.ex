defmodule Backend.Pipelines.Jobs.PipelineCoordinator do
  @moduledoc """
  Oban job that coordinates the execution of a pipeline run.

  This job:
  1. Loads the pipeline structure (nodes and edges)
  2. Builds a dependency graph
  3. Finds nodes ready to execute (no pending dependencies)
  4. Enqueues NodeExecutor jobs for ready nodes
  5. Schedules itself to check again in a few seconds
  6. Completes when all nodes are done or error occurred
  """

  use Oban.Worker,
    queue: :pipelines,
    max_attempts: 3

  require Logger
  alias Backend.Pipelines.Resources.{Pipeline, PipelineRun, Node, Edge, NodeResult}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pipeline_run_id" => pipeline_run_id}}) do
    Logger.info("[PipelineCoordinator] Starting coordination for run: #{pipeline_run_id}")

    with {:ok, run} <- load_run(pipeline_run_id),
         {:ok, run} <- ensure_running(run),
         {:ok, pipeline} <- load_pipeline_with_structure(run.pipeline_id),
         {:ok, node_results} <- load_or_create_node_results(run, pipeline) do
      # Check current status
      case check_pipeline_status(node_results) do
        {:completed, outputs} ->
          complete_pipeline(run, outputs)

        {:failed, error} ->
          fail_pipeline(run, error)

        {:running, _} ->
          # Find nodes ready to execute
          ready_nodes = find_ready_nodes(pipeline, node_results)

          if length(ready_nodes) > 0 do
            Logger.info(
              "[PipelineCoordinator] Found #{length(ready_nodes)} ready nodes, enqueueing..."
            )

            enqueue_node_executions(run, ready_nodes)
          end

          # Schedule next check in 3 seconds
          schedule_next_check(pipeline_run_id)
          :ok

        {:pending, _} ->
          # Still waiting for nodes, check again soon
          schedule_next_check(pipeline_run_id)
          :ok
      end
    else
      {:error, reason} ->
        Logger.error("[PipelineCoordinator] Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp load_run(pipeline_run_id) do
    case PipelineRun.read(pipeline_run_id) do
      {:ok, run} -> {:ok, run}
      {:error, _} -> {:error, "Pipeline run not found"}
    end
  end

  defp ensure_running(run) do
    if run.status == :pending do
      Logger.info("[PipelineCoordinator] Starting pipeline run: #{run.id}")
      PipelineRun.start(run)
    else
      {:ok, run}
    end
  end

  defp load_pipeline_with_structure(pipeline_id) do
    case Pipeline.read(pipeline_id) do
      {:ok, pipeline} ->
        # Load nodes and edges
        pipeline = Ash.load!(pipeline, [:nodes, :edges])
        {:ok, pipeline}

      {:error, _} ->
        {:error, "Pipeline not found"}
    end
  end

  defp load_or_create_node_results(run, pipeline) do
    # Load existing node results
    query =
      NodeResult
      |> Ash.Query.filter(pipeline_run_id == ^run.id)

    {:ok, existing_results} = Ash.read(query)

    existing_node_ids = MapSet.new(existing_results, & &1.node_id)

    # Create NodeResult records for any nodes that don't have one yet
    new_results =
      Enum.flat_map(pipeline.nodes, fn node ->
        if MapSet.member?(existing_node_ids, node.id) do
          []
        else
          case NodeResult.create(%{
                 pipeline_run_id: run.id,
                 node_id: node.id,
                 input_data: %{}
               }) do
            {:ok, result} -> [result]
            {:error, _} -> []
          end
        end
      end)

    all_results = existing_results ++ new_results
    {:ok, all_results}
  end

  defp check_pipeline_status(node_results) do
    statuses = Enum.map(node_results, & &1.status)

    cond do
      Enum.any?(statuses, &(&1 == :failed)) ->
        failed = Enum.find(node_results, &(&1.status == :failed))
        {:failed, failed.error_message || "Node execution failed"}

      Enum.all?(statuses, &(&1 in [:completed, :skipped])) ->
        # All done! Collect outputs
        outputs =
          node_results
          |> Enum.filter(&(&1.status == :completed))
          |> Enum.reduce(%{}, fn result, acc ->
            Map.merge(acc, result.output_data)
          end)

        {:completed, outputs}

      Enum.any?(statuses, &(&1 in [:pending, :running])) ->
        {:running, node_results}

      true ->
        {:pending, node_results}
    end
  end

  defp find_ready_nodes(pipeline, node_results) do
    # Build a map of node_id => status
    node_status_map =
      Map.new(node_results, fn result ->
        {result.node_id, result.status}
      end)

    # Build dependency map: node_id => list of dependency node_ids
    dependency_map =
      Enum.reduce(pipeline.edges, %{}, fn edge, acc ->
        Map.update(acc, edge.target_node_id, [edge.source_node_id], fn deps ->
          [edge.source_node_id | deps]
        end)
      end)

    # Find nodes that are:
    # 1. Status is :pending
    # 2. All dependencies are :completed
    Enum.filter(pipeline.nodes, fn node ->
      status = Map.get(node_status_map, node.id, :pending)
      dependencies = Map.get(dependency_map, node.id, [])

      status == :pending and
        Enum.all?(dependencies, fn dep_id ->
          Map.get(node_status_map, dep_id) == :completed
        end)
    end)
  end

  defp enqueue_node_executions(run, nodes) do
    Enum.each(nodes, fn node ->
      %{
        pipeline_run_id: run.id,
        node_id: node.id
      }
      |> Backend.Pipelines.Jobs.NodeExecutorJob.new()
      |> Oban.insert()
    end)
  end

  defp schedule_next_check(pipeline_run_id) do
    %{pipeline_run_id: pipeline_run_id}
    |> __MODULE__.new(schedule_in: 3)
    |> Oban.insert()
  end

  defp complete_pipeline(run, outputs) do
    Logger.info("[PipelineCoordinator] Pipeline run #{run.id} completed successfully")

    PipelineRun.complete(run, outputs)
    :ok
  end

  defp fail_pipeline(run, error) do
    Logger.error("[PipelineCoordinator] Pipeline run #{run.id} failed: #{error}")

    PipelineRun.fail(run, error)
    :ok
  end
end
