defmodule Backend.Services.MusicgenService do
  @moduledoc """
  Service module for interacting with Replicate's MusicGen API.
  Handles audio generation for video scenes with continuation support.
  """
require Logger

  @replicate_api_url "https://api.replicate.com/v1/predictions"
  @musicgen_model "meta/musicgen:671ac645ce5e552cc63a54a2bbff63fcf798043055d2dac5fc9e36a837eedcfb"

  @doc """
  Generates audio for a single scene using MusicGen.

  ## Parameters
    - scene: Map containing scene description and parameters
    - options: Map with optional parameters:
      - duration: Audio duration in seconds (default: from scene)
      - input_audio: Previous audio blob for continuation (optional)
      - continuation_start: Start time for continuation (default: 0)
      - continuation_end: End time for continuation (duration of previous audio)
      - prompt: Text description for music generation (default: from scene)

  ## Returns
    - {:ok, %{audio_blob: binary, total_duration: float}} on success
    - {:error, reason} on failure
  """
  def generate_scene_audio(scene, options \\ %{}) do
    case get_api_key() do
      nil ->
        Logger.info("[MusicgenService] No Replicate API key configured, using silence")
        generate_silence(scene, options)

      api_key ->
        scene_title = scene["title"] || "Unknown"
        Logger.info(
          "[MusicgenService] Generating audio for scene: #{scene_title} (API key present: #{
            String.slice(api_key, 0, 10)
          }...)"
        )
        call_musicgen_api(scene, options, api_key)
    end
  end

  @doc """
  Generates audio with continuation from a previous segment.

  ## Parameters
    - scene: Current scene to generate audio for
    - previous_audio: Map with :audio_blob and :total_duration from previous scene
    - options: Additional generation options

  ## Returns
    - {:ok, %{audio_blob: binary, total_duration: float}} on success
    - {:error, reason} on failure
  """
  def generate_with_continuation(scene, previous_audio, options \\ %{}) do
    # MusicGen continuation: use previous audio blob as input_audio
    # continuation_start = 0, continuation_end = total duration of previous audio
    continuation_options =
      options
      |> Map.put(:input_audio, previous_audio.audio_blob)
      |> Map.put(:continuation_start, 0)
      |> Map.put(:continuation_end, previous_audio.total_duration)

    Logger.info(
      "[MusicgenService] Continuing from previous audio (duration: #{previous_audio.total_duration}s)"
    )

    generate_scene_audio(scene, continuation_options)
  end

  @doc """
  Generates a complete music track for multiple scenes using continuation.

  This function generates audio for each scene sequentially, using continuation
  tokens to create a seamless audio experience across all scenes.

  ## Parameters
    - scenes: List of scene maps
    - options: Map with optional parameters:
      - default_duration: Default duration per scene in seconds (default: 4.0)
      - fade_duration: Duration of fade effects when merging (default: 1.5)
      - base_style: Base music style (default: "luxury real estate showcase")

  ## Returns
    - {:ok, final_audio_blob} on success
    - {:error, reason} on failure
  """
  def generate_music_for_scenes(scenes, options \\ %{}) do
    default_duration = Map.get(options, :default_duration, 4.0)
    
    # Diversity parameters for more dynamic audio (can be overridden per scene)
    # These will be passed through to call_musicgen_api
    # Adjusted to prevent fade: lower temperature, higher guidance for continuation
    music_diversity_options = %{
      temperature: Map.get(options, :temperature, 1.0),  # Lower for consistency (1.0-2.0 range)
      top_k: Map.get(options, :top_k, 200),  # More focused sampling (200 vs 250 default)
      top_p: Map.get(options, :top_p, 0.75),  # More focused output (0.0-1.0)
      classifier_free_guidance: Map.get(options, :classifier_free_guidance, 3)  # Higher for prompt adherence (2-4 range)
    }

    Logger.info(
      "[MusicgenService] Generating music for #{length(scenes)} scenes with continuation"
    )

    # Generate audio for each scene with continuation
    # Each scene uses the cumulative audio from all previous scenes as input
    # For continuation, duration should be the cumulative total (not just the new segment)
    total_scenes = length(scenes)
    result =
      scenes
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, nil}, fn {scene, scene_index}, {:ok, cumulative_audio} ->
        # Determine individual scene duration
        scene_duration = scene["duration"] || default_duration
        is_last_scene = (scene_index + 1) == total_scenes

        # Generate audio (with or without continuation)
        scene_result =
          case cumulative_audio do
            nil ->
              # First scene: no continuation, duration is just the scene duration
              Logger.info(
                "[MusicgenService] Scene 1: Generating initial audio (duration: #{scene_duration}s, no continuation)"
              )
              scene_opts = Map.merge(%{duration: scene_duration, is_last_scene: is_last_scene}, music_diversity_options)
              generate_scene_audio(scene, scene_opts)

            prev ->
              # Subsequent scenes: use cumulative audio from all previous scenes as input
              # Duration should be cumulative total (previous + new scene)
              scene_num = scene_index + 1
              cumulative_duration = prev.total_duration + scene_duration

              Logger.info(
                "[MusicgenService] Scene #{scene_num}: Using cumulative audio (#{prev.total_duration}s) as input, generating continuation to total duration #{cumulative_duration}s (adding #{scene_duration}s)#{if is_last_scene, do: " [LAST SCENE - will fade]", else: ""}"
              )

              # Pass cumulative duration (not just scene duration) for continuation
              # Include diversity options for more dynamic continuation
              continuation_opts = Map.merge(%{duration: cumulative_duration, is_last_scene: is_last_scene}, music_diversity_options)
              generate_with_continuation(scene, prev, continuation_opts)
          end

        case scene_result do
          {:ok, new_audio_data} ->
            # For continuation, Replicate returns the full cumulative audio (input + continuation)
            # So we don't need to merge - the returned audio_blob is already the cumulative
            case cumulative_audio do
              nil ->
                # First scene: the audio_blob is already the cumulative (just Scene 1)
                new_duration = Map.get(new_audio_data, :total_duration, scene_duration)
                cumulative = %{
                  audio_blob: new_audio_data.audio_blob,
                  total_duration: new_duration
                }
                Logger.info(
                  "[MusicgenService] Scene 1 complete: cumulative audio = #{new_duration}s"
                )
                {:cont, {:ok, cumulative}}

              prev_cumulative ->
                # Subsequent scenes: Replicate returns the full cumulative audio (input + continuation)
                # So the returned audio_blob is already the complete cumulative audio
                returned_duration = Map.get(new_audio_data, :total_duration, scene_duration)

                Logger.info(
                  "[MusicgenService] Scene #{Enum.find_index(scenes, &(&1 == scene)) + 1} complete: Replicate returned cumulative audio = #{returned_duration}s (expected: #{prev_cumulative.total_duration + scene_duration}s)"
                )

                # Use the returned audio as the new cumulative (it's already the full cumulative)
                cumulative = %{
                  audio_blob: new_audio_data.audio_blob,
                  total_duration: returned_duration
                }
                {:cont, {:ok, cumulative}}
            end

          {:error, reason} ->
            {:halt, {:error, "Failed to generate audio for scene: #{reason}"}}
        end
      end)

    case result do
      {:ok, final_cumulative} ->
        # Return the final cumulative audio (already merged)
        {:ok, final_cumulative.audio_blob}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges multiple audio segments into a single audio file with fade effects.

  ## Parameters
    - audio_segments: List of audio blobs (binaries)
    - fade_duration: Duration of fade effects in seconds (default: 1.0)

  ## Returns
    - {:ok, merged_audio_blob} on success
    - {:error, reason} on failure
  """
  def merge_audio_segments(audio_segments, fade_duration \\ 1.0) do
    Logger.info("[MusicgenService] Merging #{length(audio_segments)} audio segments")

    case audio_segments do
      [] ->
        {:error, "No audio segments to merge"}

      [single_segment] ->
        {:ok, single_segment}

      segments ->
        merge_with_ffmpeg(segments, fade_duration)
    end
  end

  @doc """
  Merges final audio with stitched video, syncing duration.

  ## Parameters
    - video_blob: Video binary
    - audio_blob: Audio binary
    - options: Map with optional parameters:
      - sync_mode: :stretch | :compress | :trim (default: :trim)

  ## Returns
    - {:ok, final_video_blob} on success
    - {:error, reason} on failure
  """
  def merge_audio_with_video(video_blob, audio_blob, options \\ %{}) do
    Logger.info("[MusicgenService] Merging audio with video")
    sync_mode = Map.get(options, :sync_mode, :trim)

    temp_video_path = create_temp_file("video", ".mp4")
    temp_audio_path = create_temp_file("audio", ".mp3")
    temp_output_path = create_temp_file("output", ".mp4")

    try do
      File.write!(temp_video_path, video_blob)
      File.write!(temp_audio_path, audio_blob)

      # Get video and audio durations
      with {:ok, video_duration} <- get_media_duration(temp_video_path),
           {:ok, audio_duration} <- get_media_duration(temp_audio_path) do
        Logger.info(
          "[MusicgenService] Video duration: #{video_duration}s, Audio duration: #{audio_duration}s"
        )

        # Build FFmpeg command based on sync mode
        ffmpeg_args =
          build_merge_args(
            temp_video_path,
            temp_audio_path,
            temp_output_path,
            video_duration,
            audio_duration,
            sync_mode
          )

        case System.cmd("ffmpeg", ffmpeg_args, stderr_to_stdout: true) do
          {_output, 0} ->
            merged_blob = File.read!(temp_output_path)
            {:ok, merged_blob}

          {output, exit_code} ->
            Logger.error("[MusicgenService] FFmpeg merge failed (exit #{exit_code}): #{output}")
            {:error, "FFmpeg merge failed"}
        end
      end
    rescue
      e ->
        Logger.error("[MusicgenService] Exception during audio/video merge: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_video_path, temp_audio_path, temp_output_path])
    end
  end

  # Private functions

  defp get_api_key do
    Application.get_env(:backend, :replicate_api_key)
  end

  defp call_musicgen_api(scene, options, api_key) do
    # Build prompt from scene description
    prompt = build_audio_prompt(scene, options)
    duration = Map.get(options, :duration, scene["duration"] || 5)

    # Determine model version based on whether we're using input_audio
    # - "large" or "stereo-large" for first scene (no continuation)
    # - "stereo-melody-large" or "melody-large" for continuation (with input_audio)
    has_input_audio = Map.has_key?(options, :input_audio) && not is_nil(Map.get(options, :input_audio))
    model_version = if has_input_audio, do: "stereo-melody-large", else: "large"

    # Get diversity parameters from options or use defaults
    # Adjusted to prevent fade: higher guidance for continuation, lower temperature
    has_input_audio = Map.has_key?(options, :input_audio) && not is_nil(Map.get(options, :input_audio))
    
    temperature = Map.get(options, :temperature, 1.0)  # Lower for consistency (1.0-2.0)
    top_k = Map.get(options, :top_k, 200)  # More focused sampling (200 vs 250 default)
    top_p = Map.get(options, :top_p, 0.75)  # More focused output (0.0-1.0)
    
    # Higher guidance for continuation to maintain energy and prevent fade
    classifier_free_guidance = if has_input_audio do
      # For continuation: use higher guidance to maintain energy
      (Map.get(options, :classifier_free_guidance, 4) |> round())
    else
      # For first scene: can be slightly lower
      (Map.get(options, :classifier_free_guidance, 3) |> round())
    end

    input_params = %{
      "prompt" => prompt,
      "duration" => duration,
      "model_version" => model_version,
      "output_format" => "mp3",
      "normalization_strategy" => "loudness",
      "temperature" => temperature,
      "top_k" => top_k,
      "classifier_free_guidance" => round(classifier_free_guidance)
    }
    
    # Only include top_p if it's > 0 (some APIs don't accept 0.0)
    input_params = if top_p > 0.0, do: Map.put(input_params, "top_p", top_p), else: input_params

    # Add continuation parameters if input_audio is provided
    input_params =
      case Map.get(options, :input_audio) do
        nil ->
          # First scene: no continuation
          Logger.info("[MusicgenService] First scene - no continuation")
          input_params

        input_audio when is_binary(input_audio) ->
          # Subsequent scenes: add continuation parameters
          continuation_start = Map.get(options, :continuation_start, 0)
          continuation_end = Map.get(options, :continuation_end, 0)

          Logger.info(
            "[MusicgenService] Using continuation: start=#{continuation_start}s, end=#{continuation_end}s"
          )

          # Upload audio to Replicate and get URL
          case encode_audio_for_replicate(input_audio) do
            nil ->
              # Upload failed, skip continuation
              Logger.warning(
                "[MusicgenService] Could not upload audio for continuation, generating without continuation"
              )
              input_params

            audio_url ->
              # Successfully uploaded, add continuation parameters
              # Log the URL format (truncate if it's a data URL)
              url_preview =
                if String.starts_with?(audio_url, "data:") do
                  # Extract size from data URL if possible
                  size_estimate = byte_size(input_audio) / 1024
                  "data:audio/mpeg;base64,...(#{Float.round(size_estimate, 2)} KB)"
                else
                  String.slice(audio_url, 0, 100)
                end

              Logger.info(
                "[MusicgenService] Adding input_audio URL: #{url_preview}, continuation_start=#{
                  continuation_start
                }, continuation_end=#{continuation_end}"
              )

              input_params
              |> Map.put("input_audio", audio_url)
              |> Map.put("continuation_start", continuation_start)
              |> Map.put("continuation_end", continuation_end)
          end

        _ ->
          input_params
      end

    # Log the final input parameters (without sensitive data)
    Logger.info(
      "[MusicgenService] API call parameters: prompt=#{String.slice(prompt, 0, 50)}..., duration=#{
        duration
      }, has_input_audio=#{Map.has_key?(input_params, "input_audio")}, model_version=#{
        input_params["model_version"]
      }, temperature=#{temperature}, top_k=#{top_k}, top_p=#{top_p}, classifier_free_guidance=#{
        classifier_free_guidance
      }"
    )

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "version" => @musicgen_model,
      "input" => input_params
    }

    Logger.info(
      "[MusicgenService] Calling Replicate API: POST #{@replicate_api_url} with model #{
        @musicgen_model
      }"
    )

    case Req.post(@replicate_api_url, json: body, headers: headers) do
      {:ok, %{status: 201, body: response}} ->
        prediction_url = response["urls"]["get"]
        Logger.info("[MusicgenService] Prediction created, polling: #{prediction_url}")
        poll_prediction(prediction_url, api_key)

      {:ok, %{status: status, body: body}} ->
        # Log full error response for debugging
        error_details =
          case body do
            %{"error" => error} -> "Error: #{inspect(error)}"
            %{"detail" => detail} -> "Detail: #{inspect(detail)}"
            _ -> "Body: #{inspect(body)}"
          end

        Logger.error(
          "[MusicgenService] Replicate API returned status #{status}: #{error_details}"
        )

        # Also log the input that caused the error (sanitized)
        Logger.error(
          "[MusicgenService] Failed request input: prompt_length=#{String.length(prompt)}, duration=#{
            duration
          }, has_input_audio=#{Map.has_key?(input_params, "input_audio")}"
        )

        {:error, "API request failed with status #{status}: #{error_details}"}

      {:error, exception} ->
        Logger.error(
          "[MusicgenService] Replicate API request failed: #{inspect(exception, pretty: true)}"
        )
        {:error, Exception.message(exception)}
    end
  end

  defp poll_prediction(url, api_key, max_attempts \\ 60) do
    headers = [{"Authorization", "Bearer #{api_key}"}]
    poll_with_backoff(url, headers, max_attempts, 0)
  end

  defp poll_with_backoff(url, headers, max_attempts, attempt) when attempt < max_attempts do
    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: response}} ->
        case response["status"] do
          "succeeded" ->
            extract_audio_result(response)

          "failed" ->
            Logger.error("[MusicgenService] Prediction failed: #{inspect(response["error"])}")
            {:error, "Audio generation failed"}

          "canceled" ->
            {:error, "Audio generation was canceled"}

          _ ->
            # Still processing, wait and retry
            Process.sleep(calculate_backoff(attempt))
            poll_with_backoff(url, headers, max_attempts, attempt + 1)
        end

      {:error, exception} ->
        Logger.error("[MusicgenService] Poll request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp poll_with_backoff(_url, _headers, max_attempts, attempt) when attempt >= max_attempts do
    {:error, "Audio generation timed out"}
  end

  defp calculate_backoff(attempt) do
    # Exponential backoff: 1s, 2s, 4s, 8s, max 10s
    min(1000 * :math.pow(2, attempt), 10_000) |> round()
  end

  defp extract_audio_result(response) do
    case response["output"] do
      audio_url when is_binary(audio_url) ->
        # Download the generated audio
        download_audio(audio_url, response)

      [audio_url | _] when is_binary(audio_url) ->
        # Handle array response
        download_audio(audio_url, response)

      _ ->
        {:error, "Invalid audio output format"}
    end
  end

  defp download_audio(audio_url, _response) do
    case Req.get(audio_url) do
      {:ok, %{status: 200, body: audio_blob}} ->
        # Get duration from the audio blob using ffprobe
        duration = get_audio_duration_from_blob(audio_blob)

        {:ok,
         %{
           audio_blob: audio_blob,
           total_duration: duration
         }}

      {:error, exception} ->
        Logger.error("[MusicgenService] Failed to download audio: #{inspect(exception)}")
        {:error, "Failed to download generated audio"}
    end
  end

  defp get_audio_duration_from_blob(audio_blob) do
    # Write blob to temp file and use ffprobe to get duration
    temp_path = create_temp_file("audio_duration", ".mp3")

    try do
      File.write!(temp_path, audio_blob)

      case get_media_duration(temp_path) do
        {:ok, duration} -> duration
        _ -> 0.0
      end
    rescue
      _ -> 0.0
    after
      cleanup_temp_files([temp_path])
    end
  end

  defp encode_audio_for_replicate(audio_blob) do
    # Replicate expects input_audio as a URL
    # According to Replicate docs, we can use their file upload API
    # or provide a publicly accessible URL
    # 
    # For now, we'll upload to Replicate's file upload endpoint
    # If that fails, we'll log a warning and skip continuation
    
    # upload_audio_to_replicate always returns {:ok, url} (either ngrok URL or data URL)
    case upload_audio_to_replicate(audio_blob) do
      {:ok, url} ->
        Logger.info("[MusicgenService] Uploaded audio to Replicate: #{url}")
        url
    end
  end

  defp upload_audio_to_replicate(audio_blob) do
    # Try to use ngrok/public URL first (preferred method)
    base_url = Application.get_env(:backend, :public_base_url)
    
    if base_url && String.starts_with?(base_url, "http") do
      # Upload to our temporary audio endpoint via ngrok
      upload_url = "#{base_url}/api/v3/testing/audio/temp-upload"
      
      # Encode as base64 for JSON
      audio_base64 = Base.encode64(audio_blob)
      
      headers = [{"Content-Type", "application/json"}]
      body = %{"audio_base64" => audio_base64}
      
      case Req.post(upload_url, json: body, headers: headers) do
        {:ok, %{status: 200, body: %{"url" => url}}} ->
          size_kb = byte_size(audio_blob) / 1024
          Logger.info(
            "[MusicgenService] Uploaded audio via ngrok: #{url} (#{Float.round(size_kb, 2)} KB)"
          )
          {:ok, url}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[MusicgenService] Temp upload failed (status #{status}), falling back to data URL: #{
              inspect(body)
            }"
          )
          fallback_to_data_url(audio_blob)

        {:error, exception} ->
          Logger.warning(
            "[MusicgenService] Temp upload error, falling back to data URL: #{inspect(exception)}"
          )
          fallback_to_data_url(audio_blob)
      end
    else
      # No ngrok URL configured, use data URL
      Logger.info(
        "[MusicgenService] No PUBLIC_BASE_URL configured, using data URL for input_audio"
      )
      fallback_to_data_url(audio_blob)
    end
  end

  defp fallback_to_data_url(audio_blob) do
    # Fallback: Try data URL (Replicate may accept it for smaller files)
    base64_audio = Base.encode64(audio_blob)
    data_url = "data:audio/mpeg;base64,#{base64_audio}"
    
    size_kb = byte_size(audio_blob) / 1024
    Logger.info("[MusicgenService] Using data URL for input_audio (#{Float.round(size_kb, 2)} KB)")
    
    {:ok, data_url}
  end


  defp build_audio_prompt(scene, options) do
    # Use provided prompt or build from scene
    Map.get(options, :prompt) || build_prompt_from_scene(scene, options)
  end

  defp build_prompt_from_scene(scene, options) do
    # Check if this is the last scene (for fade instructions)
    is_last_scene = Map.get(options, :is_last_scene, false)
    
    # Check if scene has template-based music metadata
    case {scene["music_description"], scene["music_style"], scene["music_energy"]} do
      {desc, style, energy} when not is_nil(desc) and not is_nil(style) ->
        # Use template-based music prompt with piano emphasis
        build_template_music_prompt(desc, style, energy, is_last_scene)

      _ ->
        # Fallback to legacy scene description analysis
        build_legacy_music_prompt(scene, is_last_scene)
    end
  end

  defp build_template_music_prompt(description, style, energy, is_last_scene) do
    # Simple, clean prompt - back to basics when we first added piano
    base_prompt = "Upbeat piano music, luxury vacation getaway, #{description}. #{style}, #{energy}. Instrumental, cinematic, piano-focused, smooth and flowing"
    
    # Only add fade instruction for the last scene (scene 7)
    fade_instruction = if is_last_scene do
      ". Gentle fade out at the end"
    else
      ". Smooth continuation"
    end
    
    (base_prompt <> fade_instruction)
    |> String.trim()
  end

  defp build_legacy_music_prompt(scene, is_last_scene) do
    # Extract mood and style from scene description (legacy method)
    description = scene["description"] || ""
    _title = scene["title"] || ""

    # Simple, clean prompt - back to basics when we first added piano
    base_prompt = "Upbeat piano music, luxury vacation getaway"

    mood =
      cond do
        String.contains?(description, ["exciting", "dynamic", "energy"]) -> "upbeat and energetic"
        String.contains?(description, ["calm", "peaceful", "serene"]) -> "calm and peaceful"
        String.contains?(description, ["dramatic", "intense"]) -> "dramatic and intense"
        String.contains?(description, ["elegant", "luxury"]) -> "elegant and sophisticated"
        true -> "professional and engaging"
      end

    # Only add fade instruction for the last scene (scene 7)
    fade_instruction = if is_last_scene do
      ", gentle fade out at the end"
    else
      ", smooth continuation"
    end

    "#{base_prompt}, #{mood}, instrumental, piano-focused, flowing#{fade_instruction}"
  end

  defp generate_silence(scene, options) do
    # Generate silent audio as fallback
    duration = Map.get(options, :duration, scene["duration"] || 5)

    temp_output_path = create_temp_file("silence", ".mp3")

    try do
      # Generate silence using FFmpeg
      args = [
        "-f",
        "lavfi",
        "-i",
        "anullsrc=r=44100:cl=stereo",
        "-t",
        to_string(duration),
        "-q:a",
        "9",
        "-acodec",
        "libmp3lame",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          audio_blob = File.read!(temp_output_path)
          {:ok, %{audio_blob: audio_blob, total_duration: duration}}

        {output, exit_code} ->
          Logger.error(
            "[MusicgenService] FFmpeg silence generation failed (exit #{exit_code}): #{output}"
          )

          {:error, "Failed to generate silence"}
      end
    rescue
      e ->
        Logger.error("[MusicgenService] Exception during silence generation: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_output_path])
    end
  end

  defp merge_with_ffmpeg(segments, fade_duration) do
    # Create temp files for all segments
    segment_paths =
      Enum.with_index(segments)
      |> Enum.map(fn {segment, idx} ->
        path = create_temp_file("segment_#{idx}", ".mp3")
        File.write!(path, segment)
        path
      end)

    temp_output_path = create_temp_file("merged", ".mp3")

    try do
      # Build filter complex for fading and concatenation
      filter_complex = build_fade_filter(length(segments), fade_duration)

      # Build FFmpeg arguments
      input_args = Enum.flat_map(segment_paths, fn path -> ["-i", path] end)

      ffmpeg_args =
        input_args ++
          [
            "-filter_complex",
            filter_complex,
            "-map",
            "[out]",
            "-q:a",
            "2",
            temp_output_path
          ]

      case System.cmd("ffmpeg", ffmpeg_args, stderr_to_stdout: true) do
        {_output, 0} ->
          merged_blob = File.read!(temp_output_path)
          {:ok, merged_blob}

        {output, exit_code} ->
          Logger.error("[MusicgenService] FFmpeg merge failed (exit #{exit_code}): #{output}")
          {:error, "Failed to merge audio segments"}
      end
    rescue
      e ->
        Logger.error("[MusicgenService] Exception during merge: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files(segment_paths ++ [temp_output_path])
    end
  end

  defp build_fade_filter(num_segments, fade_duration) do
    # Build filter complex for fading between segments
    # For each segment: fade out at end, fade in at start (except first/last)

    fade_filters =
      Enum.map(0..(num_segments - 1), fn idx ->
        cond do
          idx == 0 && num_segments == 1 ->
            # Single segment, no fading
            "[#{idx}:a]anull[a#{idx}]"

          idx == 0 ->
            # First segment: only fade out
            "[#{idx}:a]afade=t=out:st=#{get_fade_start_time(idx)}:d=#{fade_duration}[a#{idx}]"

          idx == num_segments - 1 ->
            # Last segment: only fade in
            "[#{idx}:a]afade=t=in:st=0:d=#{fade_duration}[a#{idx}]"

          true ->
            # Middle segments: fade in and out
            "[#{idx}:a]afade=t=in:st=0:d=#{fade_duration},afade=t=out:st=#{get_fade_start_time(idx)}:d=#{fade_duration}[a#{idx}]"
        end
      end)

    # Build concat filter
    labels = Enum.map(0..(num_segments - 1), fn idx -> "[a#{idx}]" end) |> Enum.join("")
    concat = "#{labels}concat=n=#{num_segments}:v=0:a=1[out]"

    # Combine all filters
    Enum.join(fade_filters, ";") <> ";" <> concat
  end

  defp get_fade_start_time(_segment_idx) do
    # Calculate fade start time (assuming 5s default duration per segment)
    # This should be adjusted based on actual segment duration
    max(0, 5 - 1)
  end

  defp build_merge_args(
         video_path,
         audio_path,
         output_path,
         video_duration,
         audio_duration,
         sync_mode
       ) do
    case sync_mode do
      :trim ->
        # Trim audio to match video duration
        [
          "-i",
          video_path,
          "-i",
          audio_path,
          "-t",
          to_string(video_duration),
          "-c:v",
          "copy",
          "-c:a",
          "aac",
          "-b:a",
          "192k",
          "-shortest",
          "-y",
          output_path
        ]

      :stretch ->
        # Stretch audio to match video duration (may sound unnatural)
        tempo_factor = audio_duration / video_duration

        [
          "-i",
          video_path,
          "-i",
          audio_path,
          "-filter_complex",
          "[1:a]atempo=#{tempo_factor}[a]",
          "-map",
          "0:v",
          "-map",
          "[a]",
          "-c:v",
          "copy",
          "-c:a",
          "aac",
          "-b:a",
          "192k",
          "-y",
          output_path
        ]

      :compress ->
        # Compress audio using atempo (limited to 0.5-2.0 range)
        tempo = min(max(audio_duration / video_duration, 0.5), 2.0)

        [
          "-i",
          video_path,
          "-i",
          audio_path,
          "-filter_complex",
          "[1:a]atempo=#{tempo}[a]",
          "-map",
          "0:v",
          "-map",
          "[a]",
          "-c:v",
          "copy",
          "-c:a",
          "aac",
          "-b:a",
          "192k",
          "-y",
          output_path
        ]
    end
  end

  defp get_media_duration(file_path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      file_path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {duration, _} -> {:ok, duration}
          :error -> {:error, "Invalid duration format"}
        end

      {output, _} ->
        Logger.error("[MusicgenService] ffprobe failed: #{output}")
        {:error, "Failed to get media duration"}
    end
  end

  defp create_temp_file(prefix, extension) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}#{extension}")
  end

  defp cleanup_temp_files(paths) do
    Enum.each(paths, fn path ->
      File.rm(path)
    end)
  end
end
