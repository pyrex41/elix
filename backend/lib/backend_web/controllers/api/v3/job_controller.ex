defmodule BackendWeb.Api.V3.JobController do
  @moduledoc """
  Controller for job management endpoints in API v3.
  """
  use BackendWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Workflow.Coordinator
  alias BackendWeb.Schemas.{JobSchemas, CommonSchemas}

  tags ["Jobs"]

  # Add validation plug for request casting and validation
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  operation :approve,
    summary: "Approve a job",
    description: "Approves a pending job and triggers the processing workflow",
    parameters: [
      id: [in: :path, type: :integer, description: "Job ID", required: true, example: 123]
    ],
    responses: %{
      200 => {"Job approved", "application/json", JobSchemas.JobApprovalResponse},
      404 => {"Job not found", "application/json", CommonSchemas.NotFoundResponse},
      422 => {"Cannot approve job", "application/json", CommonSchemas.ValidationErrorResponse}
    }

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
  def approve(conn, %{"id" => job_id}) do
    Logger.info("[JobController] Approving job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

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

  operation :show,
    summary: "Get job details",
    description: "Returns job status, progress, and other details",
    parameters: [
      id: [in: :path, type: :integer, description: "Job ID", required: true, example: 123]
    ],
    responses: %{
      200 => {"Job details", "application/json", JobSchemas.JobResponse},
      404 => {"Job not found", "application/json", CommonSchemas.NotFoundResponse}
    }

  @doc """
  GET /api/v3/jobs/:id

  Returns job status and progress.

  ## Parameters
    - id: The job ID

  ## Response
    - 200: Job details with status and progress
    - 404: Job not found
  """
  def show(conn, %{"id" => job_id}) do
    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

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
end
