defmodule Backend.Workflow.AudioWorker do
  @moduledoc """
  Worker module for audio generation workflow using ElevenLabs Music Service.

  Generates audio for all scenes in a single unified call.
  """
  require Logger

  alias Backend.Services.ElevenlabsMusicService
  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Workflow.Coordinator

  @doc """
  Generates audio for all scenes in a job using unified ElevenLabs generation.

  ## Parameters
    - job_id: The job ID to generate audio for
    - audio_params: Map with audio generation parameters:
      - sync_mode: How to sync final audio with video (:trim, :stretch, :compress)
      - default_duration: Default duration per scene in seconds (default: 4.0)

  ## Returns
    - {:ok, job} with updated audio_blob on success
    - {:error, reason} on failure
  """
  def generate_job_audio(job_id, audio_params \\ %{}) do
    Logger.info("[AudioWorker] Starting audio generation for job #{job_id}")

    # Load job with scenes from storyboard
    case load_job_with_scenes(job_id) do
      {:ok, job, scenes} ->
        update_job_progress(
          job,
          :in_progress,
          audio_progress("audio_generation", 95, "generating")
        )

        case generate_unified_audio(scenes, audio_params) do
          {:ok, final_audio} when is_binary(final_audio) ->
            Logger.info("[AudioWorker] Audio generation completed for job #{job_id}")
            finalize_with_video(job, final_audio, audio_params)

          {:error, reason} ->
            update_job_progress(
              job,
              :failed,
              audio_progress("audio_failed", 100, "failed", %{
                error: "Audio generation failed: #{reason}"
              })
            )

            {:error, reason}
        end

      {:error, reason} ->
        mark_audio_failed(job_id, reason)
        {:error, reason}
    end
  end

  # Private functions

  defp generate_unified_audio(scenes, audio_params) do
    Logger.info("[AudioWorker] Using unified music generation for #{length(scenes)} scenes")

    default_duration = Map.get(audio_params, :default_duration, 4.0)

    options = %{
      default_duration: default_duration,
      base_style: "luxury real estate showcase"
    }

    ElevenlabsMusicService.generate_music_for_scenes(scenes, options)
  end

  defp load_job_with_scenes(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        {:error, "Job not found"}

      %Job{storyboard: nil} ->
        {:error, "Job has no storyboard"}

      %Job{storyboard: storyboard} = job ->
        scenes = extract_scenes_from_storyboard(storyboard)

        if Enum.empty?(scenes) do
          {:error, "No scenes found in storyboard"}
        else
          {:ok, job, scenes}
        end
    end
  end

  defp extract_scenes_from_storyboard(storyboard) do
    # Storyboard may have different formats
    cond do
      is_list(storyboard) ->
        storyboard

      is_map(storyboard) && Map.has_key?(storyboard, "scenes") ->
        storyboard["scenes"]

      is_map(storyboard) && Map.has_key?(storyboard, :scenes) ->
        storyboard.scenes

      true ->
        []
    end
  end

  defp finalize_with_video(job, audio_blob, audio_params) do
    case job.result do
      nil ->
        # No video yet, just store audio
        Logger.info("[AudioWorker] Storing audio blob (no video to merge)")
        update_job_with_audio(job, audio_blob)

      video_blob ->
        # Merge audio with video
        merge_option =
          fetch_option(
            audio_params,
            :merge_with_video,
            Application.get_env(:backend, :audio_merge_with_video, true)
          )

        if merge_option do
          Logger.info("[AudioWorker] Merging audio with video")
          sync_mode = fetch_option(audio_params, :sync_mode, :trim)

          case ElevenlabsMusicService.merge_audio_with_video(video_blob, audio_blob, %{
                 sync_mode: sync_mode
               }) do
            {:ok, final_video} ->
              # Update job with merged video and store audio separately
              update_job_with_merged_result(job, final_video, audio_blob)

            {:error, reason} ->
              Logger.error("[AudioWorker] Video/audio merge failed: #{reason}")
              # Still store audio separately even if merge failed
              update_job_with_audio(job, audio_blob)
          end
        else
          # Just store audio separately
          update_job_with_audio(job, audio_blob)
        end
    end
  end

  defp update_job_with_audio(job, audio_blob) do
    # Store audio in dedicated audio_blob field
    progress = job.progress || %{}
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    audio_size = byte_size(audio_blob)

    progress_updates =
      audio_progress("audio_completed", 100, "completed", %{
        audio_generated_at: timestamp,
        audio_size: audio_size
      })

    updated_progress = Map.merge(progress, progress_updates)

    changeset =
      Backend.Schemas.Job.audio_changeset(job, %{
        audio_blob: audio_blob,
        progress: updated_progress
      })

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        Coordinator.merge_audio_if_ready(updated_job.id)
        {:ok, updated_job}

      {:error, changeset} ->
        {:error, "Failed to update job: #{inspect(changeset.errors)}"}
    end
  end

  defp update_job_with_merged_result(job, merged_video_blob, audio_blob) do
    # Store merged video in result and audio in dedicated field
    progress = job.progress || %{}
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    audio_size = byte_size(audio_blob)

    progress_updates =
      audio_progress("audio_completed", 100, "completed_and_merged", %{
        audio_generated_at: timestamp,
        audio_size: audio_size,
        video_with_audio: true
      })

    updated_progress = Map.merge(progress, progress_updates)

    changeset =
      job
      |> Ecto.Changeset.change(
        result: merged_video_blob,
        audio_blob: audio_blob,
        progress: updated_progress
      )

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        {:ok, updated_job}

      {:error, changeset} ->
        {:error, "Failed to update job: #{inspect(changeset.errors)}"}
    end
  end

  defp update_job_progress(job, _status, progress_data) do
    progress = job.progress || %{}
    normalized = normalize_progress_fields(progress_data)
    updated_progress = Map.merge(progress, normalized)

    changeset =
      job
      |> Ecto.Changeset.change(progress: updated_progress)

    Repo.update(changeset)
  end

  defp audio_progress(stage, percentage, status, extra \\ %{}) do
    extra
    |> Map.put(:stage, stage)
    |> Map.put(:percentage, percentage)
    |> Map.put(:audio_status, status)
  end

  defp normalize_progress_fields(progress_data) do
    progress_data
    |> duplicate_progress_key(:stage, "stage")
    |> duplicate_progress_key(:percentage, "percentage")
    |> duplicate_progress_key(:audio_status, "audio_status")
  end

  defp duplicate_progress_key(data, atom_key, string_key) do
    cond do
      Map.has_key?(data, atom_key) ->
        Map.put(data, string_key, Map.get(data, atom_key))

      Map.has_key?(data, string_key) ->
        Map.put(data, atom_key, Map.get(data, string_key))

      true ->
        data
    end
  end

  defp mark_audio_failed(job_id, reason) do
    case Repo.get(Job, job_id) do
      nil ->
        :ok

      job ->
        update_job_progress(
          job,
          :failed,
          audio_progress("audio_failed", 100, "failed", %{
            error: format_audio_error(reason)
          })
        )
    end
  end

  defp format_audio_error(reason) when is_binary(reason), do: reason
  defp format_audio_error(reason), do: inspect(reason)

  defp fetch_option(params, key, default) do
    cond do
      is_map(params) and Map.has_key?(params, key) ->
        Map.get(params, key)

      is_map(params) and Map.has_key?(params, Atom.to_string(key)) ->
        Map.get(params, Atom.to_string(key))

      true ->
        default
    end
  end
end
