defmodule BackendWeb.Api.V3.JobController do
  @moduledoc """
  Controller for job management endpoints in API v3.
  """
  use BackendWeb, :controller
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Workflow.Coordinator
  alias BackendWeb.ApiSchemas.{JobApprovalResponse, JobShowResponse}
  alias OpenApiSpex.Operation
  import OpenApiSpex.Operation, only: [parameter: 5, response: 3]

  @doc """
  POST /api/v3/jobs/:id/approve

  Approves a job and triggers processing workflow.

  ## Parameters
    - id: The job ID to approve

  ## Response
    - 200: Job approved successfully
    - 404: Job not found
    - 422: Job cannot be approved (invalid state)
  """
  def approve(conn, params) do
    job_id = normalize_id(params)
    Logger.info("[JobController] Approving job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        job_id_str = to_string(job_id)

        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id_str})

      job ->
        # Validate that job is in pending state
        case job.status do
          :pending ->
            # Send approval message to Coordinator
            Coordinator.approve_job(job.id)

            conn
            |> put_status(:ok)
            |> json(%{
              message: "Job approved successfully",
              job_id: job.id,
              status: "approved"
            })

          status ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: "Job cannot be approved",
              job_id: job.id,
              current_status: status,
              reason: "Job must be in pending state to be approved"
            })
        end
    end
  end

  @doc """
  GET /api/v3/jobs/:id

  Returns job status and progress.

  ## Parameters
    - id: The job ID

  ## Response
    - 200: Job details with status and progress
    - 404: Job not found
  """
  def show(conn, params) do
    job_id = normalize_id(params)

    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: to_string(job_id)})

      job ->
        # Calculate progress percentage from progress field
        progress_percentage =
          case job.progress do
            %{"percentage" => percentage} -> percentage
            %{percentage: percentage} -> percentage
            _ -> 0
          end

        # Get current stage from progress field
        current_stage =
          case job.progress do
            %{"stage" => stage} -> stage
            %{stage: stage} -> stage
            _ -> "unknown"
          end

        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job.id,
          type: job.type,
          status: job.status,
          progress_percentage: progress_percentage,
          current_stage: current_stage,
          parameters: job.parameters,
          storyboard: job.storyboard,
          inserted_at: job.inserted_at,
          updated_at: job.updated_at
        })
    end
  end

  @doc false
  @spec open_api_operation(atom) :: Operation.t()
  def open_api_operation(action) do
    apply(__MODULE__, :"#{action}_operation", [])
  end

  def approve_operation do
    %Operation{
      tags: ["jobs"],
      summary: "Approve job",
      description: "Transition a pending job into processing by dispatching it to the workflow.",
      operationId: "JobController.approve",
      parameters: [
        parameter(:id, :path, :integer, "Job ID", example: 123)
      ],
      responses: %{
        200 => response("Approval response", "application/json", JobApprovalResponse)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["jobs"],
      summary: "Get job",
      description: "Returns current status, progress, and storyboard metadata for a job.",
      operationId: "JobController.show",
      parameters: [
        parameter(:id, :path, :integer, "Job ID", example: 123)
      ],
      responses: %{
        200 => response("Job response", "application/json", JobShowResponse)
      }
    }
  end

  defp normalize_id(%{"id" => id}), do: normalize_id(id)
  defp normalize_id(%{id: id}), do: normalize_id(id)
  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
end
