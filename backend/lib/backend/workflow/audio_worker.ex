defmodule Backend.Workflow.AudioWorker do
  @moduledoc """
  Worker module for sequential audio generation workflow.

  Processes scenes sequentially using Enum.reduce_while to chain audio generation
  with continuation tokens for seamless transitions between scenes.
  """
  require Logger

  alias Backend.Services.MusicgenService
  alias Backend.Services.ElevenlabsMusicService
  alias Backend.Repo
  alias Backend.Schemas.Job

  @doc """
  Generates audio for all scenes in a job with sequential chaining.

  ## Parameters
    - job_id: The job ID to generate audio for
    - audio_params: Map with audio generation parameters:
      - fade_duration: Fade duration between segments (default: 1.5)
      - sync_mode: How to sync final audio with video (:trim, :stretch, :compress)
      - default_duration: Default duration per scene in seconds (default: 4.0)
      - use_unified_generation: Use single continuous generation vs per-scene (default: true)
      - provider: Music provider - "musicgen" or "elevenlabs" (default: "musicgen")

  ## Returns
    - {:ok, job} with updated audio_blob on success
    - {:error, reason} on failure
  """
  def generate_job_audio(job_id, audio_params \\ %{}) do
    provider = Map.get(audio_params, :provider, "musicgen")
    Logger.info("[AudioWorker] Starting audio generation for job #{job_id} with provider: #{provider}")

    # Load job with scenes from storyboard
    case load_job_with_scenes(job_id) do
      {:ok, job, scenes} ->
        # Choose generation strategy
        use_unified = Map.get(audio_params, :use_unified_generation, true)

        generation_result =
          if use_unified do
            # New unified approach: generate all scenes at once with continuation
            generate_unified_audio(scenes, audio_params, provider)
          else
            # Legacy approach: process scenes one by one
            process_scenes_sequentially(scenes, audio_params, provider)
          end

        case generation_result do
          {:ok, final_audio} when is_binary(final_audio) ->
            # Unified generation returns final audio blob directly
            finalize_with_video(job, final_audio, audio_params)

          {:ok, audio_segments} when is_list(audio_segments) ->
            # Sequential generation returns segments to merge
            case merge_and_finalize_audio(job, audio_segments, audio_params) do
              {:ok, updated_job} ->
                Logger.info("[AudioWorker] Audio generation completed for job #{job_id}")
                {:ok, updated_job}

              {:error, reason} ->
                update_job_progress(job, :failed, %{error: "Audio merge failed: #{reason}"})
                {:error, reason}
            end

          {:error, reason} ->
            update_job_progress(job, :failed, %{error: "Audio generation failed: #{reason}"})
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates audio for a single scene without job context.

  ## Parameters
    - scene: Scene map with description and parameters
    - options: Audio generation options
    - provider: Music provider - "musicgen" or "elevenlabs" (default: "musicgen")

  ## Returns
    - {:ok, audio_result} with audio_blob and continuation_token
    - {:error, reason} on failure
  """
  def generate_scene_audio(scene, options \\ %{}, provider \\ "musicgen") do
    case provider do
      "elevenlabs" ->
        ElevenlabsMusicService.generate_scene_audio(scene, options)

      _ ->
        MusicgenService.generate_scene_audio(scene, options)
    end
  end

  # Private functions

  defp generate_unified_audio(scenes, audio_params, provider) do
    Logger.info("[AudioWorker] Using unified music generation for #{length(scenes)} scenes with provider: #{provider}")

    # Use the unified generation function from the selected service
    default_duration = Map.get(audio_params, :default_duration, 4.0)
    fade_duration = Map.get(audio_params, :fade_duration, 1.5)

    options = %{
      default_duration: default_duration,
      fade_duration: fade_duration,
      base_style: "luxury real estate showcase"
    }

    case provider do
      "elevenlabs" ->
        ElevenlabsMusicService.generate_music_for_scenes(scenes, options)

      _ ->
        MusicgenService.generate_music_for_scenes(scenes, options)
    end
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

  defp process_scenes_sequentially(scenes, audio_params, provider) do
    Logger.info("[AudioWorker] Processing #{length(scenes)} scenes sequentially with provider: #{provider}")

    initial_state = %{
      segments: [],
      previous_result: nil,
      scene_index: 0,
      error: nil
    }

    result =
      Enum.reduce_while(scenes, initial_state, fn scene, state ->
        Logger.info(
          "[AudioWorker] Processing scene #{state.scene_index + 1}/#{length(scenes)}: #{scene["title"]}"
        )

        # Note: Progress tracking can be added here if needed
        # _progress = %{
        #   current_scene: state.scene_index + 1,
        #   total_scenes: length(scenes),
        #   status: "generating_audio"
        # }

        case generate_audio_for_scene(scene, state.previous_result, audio_params, provider) do
          {:ok, audio_result} ->
            # Accumulate audio segment
            updated_state = %{
              segments: state.segments ++ [audio_result.audio_blob],
              previous_result: audio_result,
              scene_index: state.scene_index + 1,
              error: nil
            }

            {:cont, updated_state}

          {:error, reason} ->
            Logger.error(
              "[AudioWorker] Scene #{state.scene_index + 1} audio generation failed: #{reason}"
            )

            # Decide whether to continue or halt based on error handling strategy
            case handle_scene_error(reason, audio_params) do
              :continue_with_silence ->
                # Generate silence for this scene and continue
                Logger.info(
                  "[AudioWorker] Continuing with silence for scene #{state.scene_index + 1}"
                )

                silence_result = generate_silence_segment(scene)

                updated_state = %{
                  segments: state.segments ++ [silence_result.audio_blob],
                  # Don't use silence for continuation
                  previous_result: nil,
                  scene_index: state.scene_index + 1,
                  error: nil
                }

                {:cont, updated_state}

              :halt ->
                # Halt processing
                {:halt, %{state | error: reason}}
            end
        end
      end)

    case result.error do
      nil ->
        {:ok, result.segments}

      error ->
        {:error, error}
    end
  end

  defp generate_audio_for_scene(scene, previous_result, audio_params, provider) do
    default_duration = Map.get(audio_params, :default_duration, 4.0)

    options = %{
      duration: scene["duration"] || default_duration,
      prompt: build_scene_prompt(scene, audio_params)
    }

    service = case provider do
      "elevenlabs" -> ElevenlabsMusicService
      _ -> MusicgenService
    end

    case previous_result do
      nil ->
        # First scene, no continuation
        service.generate_scene_audio(scene, options)

      %{continuation_token: nil} ->
        # Previous scene had no continuation token
        service.generate_scene_audio(scene, options)

      %{continuation_token: token} when is_binary(token) ->
        # Use continuation from previous scene
        service.generate_with_continuation(scene, previous_result, options)

      _ ->
        # Fallback to no continuation
        service.generate_scene_audio(scene, options)
    end
  end

  defp build_scene_prompt(scene, audio_params) do
    # Check if custom prompt provided
    case Map.get(audio_params, :prompt) do
      nil ->
        # Check if scene has template-based music metadata
        case {scene["music_description"], scene["music_style"], scene["music_energy"]} do
          {desc, style, energy} when not is_nil(desc) and not is_nil(style) ->
            # Use template-based prompt
            build_template_based_prompt(desc, style, energy)

          _ ->
            # Fallback to legacy prompt building
            build_legacy_prompt(scene)
        end

      custom_prompt ->
        custom_prompt
    end
  end

  defp build_template_based_prompt(description, style, energy) do
    """
    Luxury real estate showcase - #{description}.
    Style: #{style}.
    Energy level: #{energy}.
    Instrumental, cinematic, high production quality, seamless transitions.
    """
    |> String.trim()
    |> String.replace("\n", " ")
  end

  defp build_legacy_prompt(scene) do
    # Build from scene description (legacy)
    description = scene["description"] || ""
    scene_type = scene["scene_type"] || "general"

    base = "Cinematic background music"

    mood = determine_mood(description, scene_type)

    "#{base}, #{mood}, instrumental, seamless loop"
  end

  defp determine_mood(description, scene_type) do
    description_lower = String.downcase(description)
    scene_lower = String.downcase(scene_type)

    cond do
      String.contains?(description_lower, ["exciting", "dynamic", "energy"]) ->
        "upbeat and energetic"

      String.contains?(description_lower, ["calm", "peaceful", "serene"]) ->
        "calm and peaceful"

      String.contains?(description_lower, ["dramatic", "intense", "powerful"]) ->
        "dramatic and intense"

      String.contains?(description_lower, ["elegant", "luxury", "premium"]) ->
        "elegant and sophisticated"

      String.contains?(scene_lower, ["exterior", "outdoor"]) ->
        "bright and open"

      String.contains?(scene_lower, ["interior", "indoor"]) ->
        "warm and inviting"

      true ->
        "professional and engaging"
    end
  end

  defp handle_scene_error(_reason, audio_params) do
    error_strategy = Map.get(audio_params, :error_strategy, :continue_with_silence)

    case error_strategy do
      :continue_with_silence -> :continue_with_silence
      :halt -> :halt
      _ -> :continue_with_silence
    end
  end

  defp generate_silence_segment(scene) do
    duration = scene["duration"] || 4.0

    # Use MusicgenService for silence generation (it has the fallback)
    case MusicgenService.generate_scene_audio(scene, %{duration: duration}) do
      {:ok, result} ->
        result

      {:error, _} ->
        # Fallback: create minimal silence blob
        %{audio_blob: <<>>, continuation_token: nil}
    end
  end

  defp merge_and_finalize_audio(job, audio_segments, audio_params) do
    Logger.info("[AudioWorker] Merging #{length(audio_segments)} audio segments")

    # Remove any empty segments
    non_empty_segments = Enum.filter(audio_segments, fn seg -> byte_size(seg) > 0 end)

    case non_empty_segments do
      [] ->
        Logger.warning("[AudioWorker] No audio segments to merge")
        # Update job with progress indicating no audio
        update_job_progress(job, :completed, %{audio_status: "no_audio_generated"})
        {:ok, job}

      segments ->
        fade_duration = Map.get(audio_params, :fade_duration, 1.0)
        provider = Map.get(audio_params, :provider, "musicgen")

        service = case provider do
          "elevenlabs" -> ElevenlabsMusicService
          _ -> MusicgenService
        end

        case service.merge_audio_segments(segments, fade_duration) do
          {:ok, merged_audio} ->
            # Optionally merge with video if job has result
            finalize_with_video(job, merged_audio, audio_params)

          {:error, reason} ->
            Logger.error("[AudioWorker] Audio merge failed: #{reason}")
            {:error, reason}
        end
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
        merge_option = Map.get(audio_params, :merge_with_video, false)

        if merge_option do
          Logger.info("[AudioWorker] Merging audio with video")
          sync_mode = Map.get(audio_params, :sync_mode, :trim)
          # Both services use the same merge_audio_with_video function signature
          # Use MusicgenService for merging (it has the implementation)
          case MusicgenService.merge_audio_with_video(video_blob, audio_blob, %{
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

    updated_progress =
      Map.merge(progress, %{
        "audio_status" => "completed",
        "audio_generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "audio_size" => byte_size(audio_blob)
      })

    changeset =
      Backend.Schemas.Job.audio_changeset(job, %{
        audio_blob: audio_blob,
        progress: updated_progress
      })

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        {:ok, updated_job}

      {:error, changeset} ->
        {:error, "Failed to update job: #{inspect(changeset.errors)}"}
    end
  end

  defp update_job_with_merged_result(job, merged_video_blob, audio_blob) do
    # Store merged video in result and audio in dedicated field
    progress = job.progress || %{}

    updated_progress =
      Map.merge(progress, %{
        "audio_status" => "completed_and_merged",
        "audio_generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "audio_size" => byte_size(audio_blob),
        "video_with_audio" => true
      })

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
    updated_progress = Map.merge(progress, progress_data)

    changeset =
      job
      |> Ecto.Changeset.change(progress: updated_progress)

    Repo.update(changeset)
  end
end
