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
      - continuation_start: Binary blob to continue from (optional)
      - prompt: Text description for music generation (default: from scene)

  ## Returns
    - {:ok, %{audio_blob: binary, continuation_token: binary}} on success
    - {:error, reason} on failure
  """
  def generate_scene_audio(scene, options \\ %{}) do
    case get_api_key() do
      nil ->
        Logger.info("[MusicgenService] No Replicate API key configured, using silence")
        generate_silence(scene, options)

      api_key ->
        Logger.info("[MusicgenService] Generating audio for scene: #{scene["title"]}")
        call_musicgen_api(scene, options, api_key)
    end
  end

  @doc """
  Generates audio with continuation from a previous segment.

  ## Parameters
    - scene: Current scene to generate audio for
    - previous_audio: Map with :audio_blob and :continuation_token from previous scene
    - options: Additional generation options

  ## Returns
    - {:ok, %{audio_blob: binary, continuation_token: binary}} on success
    - {:error, reason} on failure
  """
  def generate_with_continuation(scene, previous_audio, options \\ %{}) do
    continuation_options =
      Map.put(options, :continuation_start, previous_audio.continuation_token)

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
    fade_duration = Map.get(options, :fade_duration, 1.5)

    Logger.info(
      "[MusicgenService] Generating music for #{length(scenes)} scenes with continuation"
    )

    # Generate audio for each scene with continuation
    result =
      scenes
      |> Enum.reduce_while({:ok, []}, fn scene, {:ok, acc} ->
        # Determine duration for this scene
        duration = scene["duration"] || default_duration

        # Get previous audio for continuation
        previous_audio = List.last(acc)

        # Generate audio (with or without continuation)
        scene_result =
          case previous_audio do
            nil ->
              # First scene: no continuation
              generate_scene_audio(scene, %{duration: duration})

            prev ->
              # Subsequent scenes: use continuation
              generate_with_continuation(scene, prev, %{duration: duration})
          end

        case scene_result do
          {:ok, audio_data} ->
            {:cont, {:ok, acc ++ [audio_data]}}

          {:error, reason} ->
            {:halt, {:error, "Failed to generate audio for scene: #{reason}"}}
        end
      end)

    case result do
      {:ok, audio_segments} ->
        # Extract audio blobs from segments
        blobs = Enum.map(audio_segments, & &1.audio_blob)

        # Merge all segments with fade effects
        merge_audio_segments(blobs, fade_duration)

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

    input_params = %{
      "prompt" => prompt,
      "duration" => duration,
      "model_version" => "stereo-large",
      "output_format" => "mp3",
      "normalization_strategy" => "loudness"
    }

    # Add continuation if provided
    input_params =
      case Map.get(options, :continuation_start) do
        nil -> input_params
        continuation -> Map.put(input_params, "continuation_start", continuation)
      end

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "version" => @musicgen_model,
      "input" => input_params
    }

    case Req.post(@replicate_api_url, json: body, headers: headers) do
      {:ok, %{status: 201, body: response}} ->
        # Poll for completion
        prediction_url = response["urls"]["get"]
        poll_prediction(prediction_url, api_key)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[MusicgenService] Replicate API returned status #{status}: #{inspect(body)}"
        )

        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[MusicgenService] Replicate API request failed: #{inspect(exception)}")
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

  defp download_audio(audio_url, response) do
    case Req.get(audio_url) do
      {:ok, %{status: 200, body: audio_blob}} ->
        # Extract continuation token if available for chaining
        continuation_token = extract_continuation_token(response)

        {:ok,
         %{
           audio_blob: audio_blob,
           continuation_token: continuation_token
         }}

      {:error, exception} ->
        Logger.error("[MusicgenService] Failed to download audio: #{inspect(exception)}")
        {:error, "Failed to download generated audio"}
    end
  end

  defp extract_continuation_token(response) do
    # MusicGen may provide continuation data for seamless chaining
    # This is model-specific and may need adjustment
    get_in(response, ["output_metadata", "continuation"]) ||
      get_in(response, ["metrics", "continuation_token"])
  end

  defp build_audio_prompt(scene, options) do
    # Use provided prompt or build from scene
    Map.get(options, :prompt) || build_prompt_from_scene(scene)
  end

  defp build_prompt_from_scene(scene) do
    # Check if scene has template-based music metadata
    case {scene["music_description"], scene["music_style"], scene["music_energy"]} do
      {desc, style, energy} when not is_nil(desc) and not is_nil(style) ->
        # Use template-based music prompt
        build_template_music_prompt(desc, style, energy)

      _ ->
        # Fallback to legacy scene description analysis
        build_legacy_music_prompt(scene)
    end
  end

  defp build_template_music_prompt(description, style, energy) do
    """
    Luxury real estate showcase - #{description}.
    Style: #{style}.
    Energy level: #{energy}.
    Instrumental, cinematic, high production quality.
    """
    |> String.trim()
    |> String.replace("\n", " ")
  end

  defp build_legacy_music_prompt(scene) do
    # Extract mood and style from scene description (legacy method)
    description = scene["description"] || ""
    _title = scene["title"] || ""

    # Create a music prompt based on scene content
    base_prompt = "Cinematic background music"

    mood =
      cond do
        String.contains?(description, ["exciting", "dynamic", "energy"]) -> "upbeat and energetic"
        String.contains?(description, ["calm", "peaceful", "serene"]) -> "calm and peaceful"
        String.contains?(description, ["dramatic", "intense"]) -> "dramatic and intense"
        String.contains?(description, ["elegant", "luxury"]) -> "elegant and sophisticated"
        true -> "professional and engaging"
      end

    "#{base_prompt}, #{mood}, instrumental"
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
          {:ok, %{audio_blob: audio_blob, continuation_token: nil}}

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
