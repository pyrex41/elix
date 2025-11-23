defmodule BackendWeb.Api.V3.SceneController do
  @moduledoc """
  Controller for managing job scenes (sub_jobs) in API v3.

  Provides CRUD operations for scenes within a job:
  - List all scenes for a job
  - Get specific scene details
  - Update scene data
  - Regenerate a scene
  - Delete a scene
  """
  use BackendWeb, :controller
  require Logger

  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Schemas.SubJob
  alias Backend.Workflow.Coordinator
  import Ecto.Query

  @doc """
  GET /api/v3/jobs/:job_id/scenes

  Lists all scenes (sub_jobs) for a specific job.

  ## Parameters
    - job_id: The parent job ID

  ## Response
    - 200: List of scenes with their details
    - 404: Job not found
  """
  def index(conn, %{"job_id" => job_id}) do
    Logger.info("[SceneController] Listing scenes for job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      job ->
        # Load all sub_jobs for this job
        scenes =
          SubJob
          |> where([s], s.job_id == ^job.id)
          |> order_by([s], asc: s.inserted_at)
          |> Repo.all()

        # Calculate overall progress
        total_scenes = length(scenes)
        completed_scenes = Enum.count(scenes, fn s -> s.status == :completed end)

        progress_percentage =
          if total_scenes > 0 do
            Float.round(completed_scenes / total_scenes * 100, 2)
          else
            0
          end

        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job.id,
          total_scenes: total_scenes,
          completed_scenes: completed_scenes,
          progress_percentage: progress_percentage,
          scenes: Enum.map(scenes, &format_scene/1)
        })
    end
  end

  @doc """
  GET /api/v3/jobs/:job_id/scenes/:scene_id

  Gets details for a specific scene.

  ## Parameters
    - job_id: The parent job ID
    - scene_id: The scene (sub_job) ID

  ## Response
    - 200: Scene details
    - 404: Job or scene not found
    - 422: Scene does not belong to job
  """
  def show(conn, %{"job_id" => job_id, "scene_id" => scene_id}) do
    Logger.info("[SceneController] Getting scene #{scene_id} for job #{job_id}")

    with {:ok, job} <- get_job(job_id),
         {:ok, scene} <- get_scene(scene_id),
         :ok <- validate_scene_belongs_to_job(scene, job) do
      conn
      |> put_status(:ok)
      |> json(%{
        scene: format_scene_detailed(scene),
        job_id: job.id,
        job_status: job.status
      })
    else
      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, :scene_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scene not found", scene_id: scene_id})

      {:error, :scene_job_mismatch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Scene does not belong to this job",
          scene_id: scene_id,
          job_id: job_id
        })
    end
  end

  @doc """
  PUT /api/v3/jobs/:job_id/scenes/:scene_id

  Updates a scene's data and notifies the Workflow Coordinator.

  ## Parameters
    - job_id: The parent job ID
    - scene_id: The scene (sub_job) ID
    - status: New status (optional)
    - provider_id: Provider ID for the scene (optional)

  ## Response
    - 200: Scene updated successfully
    - 404: Job or scene not found
    - 422: Validation error or scene doesn't belong to job
  """
  def update(conn, %{"job_id" => job_id, "scene_id" => scene_id} = params) do
    Logger.info("[SceneController] Updating scene #{scene_id} for job #{job_id}")

    with {:ok, job} <- get_job(job_id),
         {:ok, scene} <- get_scene(scene_id),
         :ok <- validate_scene_belongs_to_job(scene, job),
         {:ok, updated_scene} <- update_scene(scene, params),
         :ok <- notify_coordinator_update(job, updated_scene) do
      # Recalculate job progress
      recalculate_job_progress(job)

      conn
      |> put_status(:ok)
      |> json(%{
        message: "Scene updated successfully",
        scene: format_scene_detailed(updated_scene),
        job_id: job.id
      })
    else
      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, :scene_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scene not found", scene_id: scene_id})

      {:error, :scene_job_mismatch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Scene does not belong to this job",
          scene_id: scene_id,
          job_id: job_id
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Validation failed",
          details: format_changeset_errors(changeset)
        })

      {:error, reason} ->
        Logger.error("[SceneController] Update failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to update scene"})
    end
  end

  @doc """
  POST /api/v3/jobs/:job_id/scenes/:scene_id/regenerate

  Marks a scene for regeneration and notifies the Workflow Coordinator.

  ## Parameters
    - job_id: The parent job ID
    - scene_id: The scene (sub_job) ID

  ## Response
    - 200: Scene marked for regeneration
    - 404: Job or scene not found
    - 422: Scene cannot be regenerated (invalid state) or doesn't belong to job
  """
  def regenerate(conn, %{"job_id" => job_id, "scene_id" => scene_id}) do
    Logger.info("[SceneController] Regenerating scene #{scene_id} for job #{job_id}")

    with {:ok, job} <- get_job(job_id),
         {:ok, scene} <- get_scene(scene_id),
         :ok <- validate_scene_belongs_to_job(scene, job),
         :ok <- validate_scene_can_regenerate(scene),
         {:ok, regenerated_scene} <- mark_scene_for_regeneration(scene),
         :ok <- notify_coordinator_regenerate(job, regenerated_scene) do
      # Recalculate job progress
      recalculate_job_progress(job)

      conn
      |> put_status(:ok)
      |> json(%{
        message: "Scene marked for regeneration",
        scene: format_scene_detailed(regenerated_scene),
        job_id: job.id
      })
    else
      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, :scene_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scene not found", scene_id: scene_id})

      {:error, :scene_job_mismatch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Scene does not belong to this job",
          scene_id: scene_id,
          job_id: job_id
        })

      {:error, :cannot_regenerate, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Scene cannot be regenerated",
          scene_id: scene_id,
          reason: reason
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Validation failed",
          details: format_changeset_errors(changeset)
        })

      {:error, reason} ->
        Logger.error("[SceneController] Regeneration failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to regenerate scene"})
    end
  end

  @doc """
  DELETE /api/v3/jobs/:job_id/scenes/:scene_id

  Deletes a scene and recalculates job progress.

  ## Parameters
    - job_id: The parent job ID
    - scene_id: The scene (sub_job) ID

  ## Response
    - 200: Scene deleted successfully
    - 404: Job or scene not found
    - 422: Scene cannot be deleted or doesn't belong to job
  """
  def delete(conn, %{"job_id" => job_id, "scene_id" => scene_id}) do
    Logger.info("[SceneController] Deleting scene #{scene_id} for job #{job_id}")

    with {:ok, job} <- get_job(job_id),
         {:ok, scene} <- get_scene(scene_id),
         :ok <- validate_scene_belongs_to_job(scene, job),
         :ok <- validate_scene_can_delete(scene, job),
         {:ok, _deleted_scene} <- delete_scene(scene),
         :ok <- notify_coordinator_delete(job, scene_id) do
      # Recalculate job progress
      recalculate_job_progress(job)

      conn
      |> put_status(:ok)
      |> json(%{
        message: "Scene deleted successfully",
        scene_id: scene_id,
        job_id: job.id
      })
    else
      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, :scene_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Scene not found", scene_id: scene_id})

      {:error, :scene_job_mismatch} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Scene does not belong to this job",
          scene_id: scene_id,
          job_id: job_id
        })

      {:error, :cannot_delete, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Scene cannot be deleted",
          scene_id: scene_id,
          reason: reason
        })

      {:error, reason} ->
        Logger.error("[SceneController] Deletion failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to delete scene"})
    end
  end

  # Private helper functions

  defp get_job(job_id) do
    case Repo.get(Job, job_id) do
      nil -> {:error, :job_not_found}
      job -> {:ok, job}
    end
  end

  defp get_scene(scene_id) do
    case Repo.get(SubJob, scene_id) do
      nil -> {:error, :scene_not_found}
      scene -> {:ok, scene}
    end
  end

  defp validate_scene_belongs_to_job(scene, job) do
    if scene.job_id == job.id do
      :ok
    else
      {:error, :scene_job_mismatch}
    end
  end

  defp validate_scene_can_regenerate(scene) do
    case scene.status do
      status when status in [:completed, :failed] ->
        :ok

      status ->
        {:error, :cannot_regenerate, "Scene is currently #{status}"}
    end
  end

  defp validate_scene_can_delete(_scene, job) do
    # Prevent deletion if job is actively processing
    case job.status do
      :processing ->
        {:error, :cannot_delete, "Cannot delete scene while job is processing"}

      _ ->
        :ok
    end
  end

  defp update_scene(scene, params) do
    # Extract allowed update fields
    update_attrs =
      params
      |> Map.take(["status", "provider_id"])
      |> Enum.into(%{}, fn {k, v} -> {String.to_atom(k), v} end)

    scene
    |> SubJob.changeset(update_attrs)
    |> Repo.update()
  end

  defp mark_scene_for_regeneration(scene) do
    scene
    |> SubJob.changeset(%{
      status: :pending,
      provider_id: nil,
      video_blob: nil
    })
    |> Repo.update()
  end

  defp delete_scene(scene) do
    Repo.delete(scene)
  end

  defp notify_coordinator_update(job, scene) do
    Logger.debug("[SceneController] Notifying coordinator of scene update: #{scene.id}")

    # Send message to Coordinator about scene update
    # The coordinator can handle this asynchronously
    GenServer.cast(Coordinator, {:scene_updated, job.id, scene.id, scene.status})

    :ok
  end

  defp notify_coordinator_regenerate(job, scene) do
    Logger.info("[SceneController] Notifying coordinator of scene regeneration: #{scene.id}")

    # Send message to Coordinator to re-process this scene
    GenServer.cast(Coordinator, {:scene_regenerate, job.id, scene.id})

    :ok
  end

  defp notify_coordinator_delete(job, scene_id) do
    Logger.info("[SceneController] Notifying coordinator of scene deletion: #{scene_id}")

    # Send message to Coordinator about scene deletion
    GenServer.cast(Coordinator, {:scene_deleted, job.id, scene_id})

    :ok
  end

  defp recalculate_job_progress(job) do
    Logger.debug("[SceneController] Recalculating progress for job #{job.id}")

    # Get all scenes for this job
    scenes =
      SubJob
      |> where([s], s.job_id == ^job.id)
      |> Repo.all()

    total_scenes = length(scenes)

    if total_scenes > 0 do
      completed_scenes = Enum.count(scenes, fn s -> s.status == :completed end)
      processing_scenes = Enum.count(scenes, fn s -> s.status == :processing end)
      failed_scenes = Enum.count(scenes, fn s -> s.status == :failed end)

      progress_percentage = Float.round(completed_scenes / total_scenes * 100, 2)

      # Determine stage based on scene statuses
      stage =
        cond do
          completed_scenes == total_scenes -> "completed"
          processing_scenes > 0 -> "processing"
          failed_scenes > 0 -> "processing_with_errors"
          true -> "pending"
        end

      progress_data = %{
        percentage: progress_percentage,
        stage: stage,
        total_scenes: total_scenes,
        completed_scenes: completed_scenes,
        processing_scenes: processing_scenes,
        failed_scenes: failed_scenes
      }

      # Update job progress via Coordinator
      Coordinator.update_progress(job.id, progress_data)
    end

    :ok
  end

  defp format_scene(scene) do
    %{
      id: scene.id,
      status: scene.status,
      provider_id: scene.provider_id,
      has_video: !is_nil(scene.video_blob),
      inserted_at: scene.inserted_at,
      updated_at: scene.updated_at
    }
  end

  defp format_scene_detailed(scene) do
    %{
      id: scene.id,
      job_id: scene.job_id,
      status: scene.status,
      provider_id: scene.provider_id,
      has_video: !is_nil(scene.video_blob),
      video_blob_size: if(scene.video_blob, do: byte_size(scene.video_blob), else: 0),
      inserted_at: scene.inserted_at,
      updated_at: scene.updated_at
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
