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

  # Storyboard scene editing constants
  @min_scene_duration 3.0
  @max_scene_duration 8.0

  @doc """
  PATCH /api/v3/jobs/:job_id/storyboard/scenes/:scene_index

  Edits a scene in the job's storyboard. Only allowed when job is pending.
  Preserves existing prompt when changing assets.

  ## Parameters
    - job_id: The parent job ID
    - scene_index: Zero-based index of scene in storyboard
    - asset_ids: New asset IDs (optional)
    - duration: New duration in seconds (optional, #{@min_scene_duration}-#{@max_scene_duration}s)

  ## Response
    - 200: Scene edited successfully
    - 404: Job not found or scene index out of bounds
    - 409: Job not in pending status
    - 422: Validation error (duration out of range, asset not found)
  """
  def edit_storyboard_scene(conn, %{"job_id" => job_id, "scene_index" => scene_index_str} = params) do
    Logger.info("[SceneController] Editing storyboard scene #{scene_index_str} for job #{job_id}")

    with {:ok, job} <- get_job(job_id),
         :ok <- validate_job_pending(job),
         {:ok, scene_index} <- parse_scene_index(scene_index_str),
         {:ok, scenes} <- get_storyboard_scenes(job),
         {:ok, scene} <- get_scene_at_index(scenes, scene_index),
         {:ok, updated_scene} <- apply_storyboard_scene_edits(scene, params),
         {:ok, updated_job} <- persist_storyboard_scene_update(job, scenes, scene_index, updated_scene) do
      conn
      |> put_status(:ok)
      |> json(%{
        message: "Scene updated successfully",
        scene: format_storyboard_scene(updated_scene, scene_index),
        scene_index: scene_index,
        job_id: job.id,
        total_duration:
          get_in(updated_job.storyboard || %{}, ["total_duration"]) ||
            get_in(updated_job.storyboard || %{}, [:total_duration])
      })
    else
      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id})

      {:error, :job_not_pending} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "Scene can only be edited while job is pending",
          job_id: job_id
        })

      {:error, :invalid_scene_index} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "Invalid scene index",
          scene_index: scene_index_str
        })

      {:error, :scene_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "Scene index out of bounds",
          scene_index: scene_index_str
        })

      {:error, :no_storyboard} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Job has no storyboard",
          job_id: job_id
        })

      {:error, :duration_out_of_range} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Duration must be between #{@min_scene_duration} and #{@max_scene_duration} seconds",
          min: @min_scene_duration,
          max: @max_scene_duration
        })

      {:error, reason} ->
        Logger.error("[SceneController] Storyboard scene edit failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to update scene"})
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

  # Storyboard scene editing helper functions

  defp validate_job_pending(%Job{status: :pending}), do: :ok
  defp validate_job_pending(_job), do: {:error, :job_not_pending}

  defp parse_scene_index(index_str) when is_binary(index_str) do
    case Integer.parse(index_str) do
      {idx, ""} when idx >= 0 -> {:ok, idx}
      _ -> {:error, :invalid_scene_index}
    end
  end

  defp get_storyboard_scenes(%Job{storyboard: nil}), do: {:error, :no_storyboard}

  defp get_storyboard_scenes(%Job{storyboard: storyboard}) do
    scenes =
      cond do
        is_map(storyboard) && Map.has_key?(storyboard, "scenes") -> storyboard["scenes"]
        is_map(storyboard) && Map.has_key?(storyboard, :scenes) -> storyboard.scenes
        true -> nil
      end

    if is_list(scenes) do
      {:ok, scenes}
    else
      {:error, :no_storyboard}
    end
  end

  defp get_scene_at_index(scenes, index) when is_list(scenes) and index >= 0 do
    case Enum.at(scenes, index) do
      nil -> {:error, :scene_not_found}
      scene -> {:ok, scene}
    end
  end

  defp apply_storyboard_scene_edits(scene, params) do
    scene
    |> maybe_update_asset_ids(params)
    |> maybe_update_duration(params)
  end

  defp maybe_update_asset_ids({:error, _} = error, _params), do: error

  defp maybe_update_asset_ids(scene, %{"asset_ids" => asset_ids}) when is_list(asset_ids) do
    # Preserve prompt - just update asset_ids
    Map.put(scene, "asset_ids", asset_ids)
  end

  defp maybe_update_asset_ids(scene, %{"asset_id" => asset_id}) when is_binary(asset_id) do
    # Single asset_id convenience - convert to list
    Map.put(scene, "asset_ids", [asset_id])
  end

  defp maybe_update_asset_ids(scene, _params), do: scene

  defp maybe_update_duration({:error, _} = error, _params), do: error

  defp maybe_update_duration(scene, %{"duration" => duration}) when is_number(duration) do
    if duration >= @min_scene_duration and duration <= @max_scene_duration do
      Map.put(scene, "duration", duration * 1.0)
    else
      {:error, :duration_out_of_range}
    end
  end

  defp maybe_update_duration(scene, _params), do: scene

  defp persist_storyboard_scene_update(job, scenes, index, updated_scene) do
    updated_scenes = List.replace_at(scenes, index, updated_scene)
    new_total_duration = calculate_storyboard_total_duration(updated_scenes)

    updated_storyboard =
      job.storyboard
      |> Map.put("scenes", updated_scenes)
      |> Map.put("total_duration", new_total_duration)

    job
    |> Job.changeset(%{storyboard: updated_storyboard})
    |> Repo.update()
  end

  defp calculate_storyboard_total_duration(scenes) do
    Enum.reduce(scenes, 0.0, fn scene, acc ->
      duration =
        case Map.get(scene, "duration") || Map.get(scene, :duration) do
          value when is_number(value) -> value * 1.0
          value when is_binary(value) ->
            case Float.parse(value) do
              {float_val, _} -> float_val
              :error -> 0.0
            end
          _ -> 0.0
        end

      acc + duration
    end)
  end

  defp format_storyboard_scene(scene, index) do
    %{
      index: index,
      title: scene["title"] || scene[:title],
      description: scene["description"] || scene[:description],
      duration: scene["duration"] || scene[:duration],
      asset_ids: scene["asset_ids"] || scene[:asset_ids],
      prompt: scene["prompt"] || scene[:prompt],
      scene_type: scene["scene_type"] || scene[:scene_type]
    }
  end
end
