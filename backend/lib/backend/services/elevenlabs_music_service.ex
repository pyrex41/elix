defmodule Backend.Services.ElevenlabsMusicService do
  @moduledoc """
  Service module for interacting with ElevenLabs Music API.
  Handles dynamic-duration audio generation for video scenes.
  """
  require Logger

  @elevenlabs_api_url "https://api.elevenlabs.io/v1/music/compose"

  # Generation parameters
  @generation_buffer_seconds 8.0
  @default_scene_duration 4.0
  @fade_duration_seconds 2.0
  @bpm 120
  @api_receive_timeout_ms 120_000

  @doc """
  Generates audio for a single scene.
  Convenience wrapper around generate_music_for_scenes/2.

  ## Returns
    - {:ok, %{audio_blob: binary, continuation_token: nil}} on success
    - {:error, reason} on failure
  """
  def generate_scene_audio(scene, options \\ %{}) do
    case generate_music_for_scenes([scene], options) do
      {:ok, audio_blob} ->
        {:ok, %{audio_blob: audio_blob, continuation_token: nil}}
      error -> error
    end
  end

  @doc """
  Generates a complete music track for multiple scenes with dynamic duration support.

  Calculates the total duration from scenes, generates a track with 8s buffer,
  then trims and fades to exact duration needed.

  ## Parameters
    - scenes: List of scene maps
    - options: Map with optional parameters:
      - default_duration: Default duration per scene in seconds (default: 4.0)

  ## Returns
    - {:ok, final_audio_blob} on success
    - {:error, reason} on failure
  """
  def generate_music_for_scenes(scenes, options \\ %{}) do
    default_duration = Map.get(options, :default_duration, @default_scene_duration)

    # Calculate actual duration needed from scenes
    scene_durations = Enum.map(scenes, fn scene -> scene["duration"] || default_duration end)
    target_duration = Enum.sum(scene_durations)

    # Generate with buffer for clean trimming
    generation_duration = target_duration + @generation_buffer_seconds

    Logger.info("[ElevenlabsMusicService] Target: #{target_duration}s, scenes: #{length(scenes)}, durations: #{inspect(scene_durations)}")
    Logger.info("[ElevenlabsMusicService] Generating #{generation_duration}s track for #{length(scenes)} scenes (will trim to #{target_duration}s)")

    case generate_full_track(scenes, generation_duration, options) do
      {:ok, audio_blob} ->
        fade_start = max(0, target_duration - @fade_duration_seconds)
        trim_and_fade_to_duration(audio_blob, target_duration, fade_start, @fade_duration_seconds)
      error -> error
    end
  end

  defp generate_full_track(scenes, duration, options) do
    # Use consistent seed
    seed = Map.get(options, :seed, :erlang.phash2(scenes) |> rem(4294967295))
    Logger.info("[ElevenlabsMusicService] Using seed: #{seed}")

    # Build a single comprehensive prompt with all scenes and timestamps
    # NO fade instructions - we'll handle fade with FFmpeg
    # 120 BPM = 2 beats per second = 8 beats per 4 seconds (perfect for scene changes)
    combined_prompt = build_prompt_with_timestamps(scenes, duration)

    # Create a single scene map for generation with buffer
    full_scene = %{
      "title" => "Complete Track",
      "description" => "Luxury vacation getaway showcase",
      "duration" => duration,
      "music_description" => combined_prompt,
      "music_style" => "cinematic, piano-focused, smooth",
      "music_energy" => "medium-high"
    }

    # Generate track using simple compose endpoint
    generate_options =
      options
      |> Map.put(:duration, duration)
      |> Map.put(:prompt, combined_prompt)
      |> Map.put(:seed, seed)

    case get_api_key() do
      nil ->
        Logger.info("[ElevenlabsMusicService] No ElevenLabs API key configured, using silence")
        case generate_silence(full_scene, generate_options) do
          {:ok, %{audio_blob: audio_blob}} -> {:ok, audio_blob}
          error -> error
        end

      api_key ->
        Logger.info("[ElevenlabsMusicService] Generating #{duration}s track with single prompt (#{length(scenes)} scenes, no fade instructions, #{@bpm} BPM)")
        case call_elevenlabs_api(full_scene, generate_options, api_key) do
          {:ok, %{audio_blob: audio_blob}} -> {:ok, audio_blob}
          error -> error
        end
    end
  end

  defp build_prompt_with_timestamps(scenes, total_duration) do
    # Build a prompt with all scenes and explicit timestamps for scene changes
    # Use actual scene durations instead of hardcoded 4-second intervals
    {scene_descriptions, _scene_boundaries} =
      scenes
      |> Enum.reduce({[], 0.0}, fn scene, {descs, time_acc} ->
        scene_dur = scene["duration"] || @default_scene_duration
        start_time = time_acc
        end_time = time_acc + scene_dur

        scene_desc = scene["music_description"] || scene["description"] || ""
        scene_title = scene["title"] || "Scene"
        desc = "#{trunc(start_time)}-#{trunc(end_time)}s: #{scene_title} - #{scene_desc}"

        {descs ++ [desc], end_time}
      end)

    scene_descriptions_text = Enum.join(scene_descriptions, ". ")

    base_style = "luxury vacation getaway, cinematic, piano-focused, smooth, medium-high energy"

    # BPM calculation for scene alignment
    beats_per_second = @bpm / 60
    avg_scene_duration = if length(scenes) > 0, do: total_duration / length(scenes), else: @default_scene_duration
    beats_per_scene = trunc(avg_scene_duration * beats_per_second)

    # Calculate beat markers at actual scene boundaries
    {_, beat_markers_list} =
      scenes
      |> Enum.reduce({0.0, [0]}, fn scene, {time_acc, markers} ->
        scene_dur = scene["duration"] || @default_scene_duration
        new_time = time_acc + scene_dur
        {new_time, markers ++ [trunc(new_time)]}
      end)

    beat_markers = beat_markers_list |> Enum.uniq() |> Enum.map(&"#{&1}s") |> Enum.join(", ")

    "#{base_style}. #{trunc(total_duration)}-second instrumental track with scene transitions at #{beat_markers}. #{scene_descriptions_text}. #{@bpm} BPM (#{beats_per_second} beats per second, ~#{beats_per_scene} beats per scene change) with strong beat markers at scene transitions. CRITICAL: Maintain FULL energy and volume throughout the entire track. NO fade in. NO fade out. NO volume reduction. Keep constant, steady energy from start to finish. Smooth, flowing transitions between scenes. Instrumental, piano-focused."
  end

  defp trim_and_fade_to_duration(audio_blob, target_duration, fade_start_sec, fade_duration_sec) do
    # Trim to target duration and apply fade out at the end
    # This gives us full control - no early fade from ElevenLabs
    temp_input_path = create_temp_file("input_audio", ".mp3")
    temp_output_path = create_temp_file("trimmed_faded_audio", ".mp3")

    try do
      File.write!(temp_input_path, audio_blob)

      # Trim and apply fade from specified start position
      filter_complex = "[0:a]atrim=0:#{target_duration},asetpts=PTS-STARTPTS,afade=t=out:st=#{fade_start_sec}:d=#{fade_duration_sec}[out]"

      args = [
        "-i", temp_input_path,
        "-filter_complex", filter_complex,
        "-map", "[out]",
        "-t", "#{target_duration}",
        "-q:a", "2",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          final_blob = File.read!(temp_output_path)
          Logger.info("[ElevenlabsMusicService] Trimmed to #{target_duration}s and applied fade out at #{fade_start_sec}-#{fade_start_sec + fade_duration_sec}s")
          {:ok, final_blob}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] Trim and fade failed (exit #{exit_code}): #{output}")
          {:error, "Trim and fade failed"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during trim and fade: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_input_path, temp_output_path])
    end
  end

  @doc """
  Merges audio track with video using FFmpeg.

  ## Parameters
    - video_blob: Binary video data
    - audio_blob: Binary audio data
    - options: Map with optional parameters

  ## Returns
    - {:ok, merged_video_blob} on success
    - {:error, reason} on failure
  """
  def merge_audio_with_video(video_blob, audio_blob, _options \\ %{}) do
    temp_video_path = create_temp_file("video", ".mp4")
    temp_audio_path = create_temp_file("audio", ".mp3")
    temp_output_path = create_temp_file("output", ".mp4")

    try do
      File.write!(temp_video_path, video_blob)
      File.write!(temp_audio_path, audio_blob)

      # FFmpeg args: replace video's audio with generated audio
      # -shortest ensures output matches the shorter of video or audio
      args = [
        "-i", temp_video_path,
        "-i", temp_audio_path,
        "-c:v", "copy",
        "-c:a", "aac",
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-shortest",
        "-y",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          merged_blob = File.read!(temp_output_path)
          Logger.info("[ElevenlabsMusicService] Successfully merged audio with video")
          {:ok, merged_blob}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] FFmpeg merge failed (exit #{exit_code}): #{output}")
          {:error, "FFmpeg merge failed"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during merge: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_video_path, temp_audio_path, temp_output_path])
    end
  end

  @doc """
  Generates silence as fallback when API is unavailable.

  ## Parameters
    - scene: Scene map with duration
    - options: Map with optional parameters

  ## Returns
    - {:ok, %{audio_blob: binary, total_duration: float}} on success
    - {:error, reason} on failure
  """
  def generate_silence(scene, options \\ %{}) do
    duration = Map.get(options, :duration, scene["duration"] || @default_scene_duration)
    temp_output_path = create_temp_file("silence", ".mp3")

    try do
      # Generate silence using FFmpeg
      args = [
        "-f", "lavfi",
        "-i", "anullsrc=r=44100:cl=stereo",
        "-t", "#{duration}",
        "-q:a", "2",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          silence_blob = File.read!(temp_output_path)
          Logger.info("[ElevenlabsMusicService] Generated #{duration}s of silence")
          {:ok, %{audio_blob: silence_blob, total_duration: duration}}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] Silence generation failed (exit #{exit_code}): #{output}")
          {:error, "Silence generation failed"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during silence generation: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_output_path])
    end
  end

  # Private helper functions

  defp call_elevenlabs_api(scene, options, api_key) do
    # Build prompt from scene description
    prompt = build_audio_prompt(scene, options)
    duration = Map.get(options, :duration, scene["duration"] || 28.0)
    duration_ms = round(duration * 1000)

    # ElevenLabs API requires music_length_ms between 10000ms (10s) and 300000ms (5min)
    music_length_ms = max(duration_ms, 10_000)

    # Build request body - simple prompt-based generation
    body = %{
      prompt: prompt,
      music_length_ms: music_length_ms,
      output_format: "mp3_44100_128",
      force_instrumental: true,
      seed: Map.get(options, :seed)
    }

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    Logger.info(
      "[ElevenlabsMusicService] Calling ElevenLabs API: POST #{@elevenlabs_api_url} with prompt length=#{String.length(prompt)}, music_length_ms=#{music_length_ms}ms"
    )

    # Add timeout for long requests (music generation can take 60-90 seconds)
    case Req.post(@elevenlabs_api_url, json: body, headers: headers, decode_body: false, receive_timeout: @api_receive_timeout_ms) do
      {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
        # ElevenLabs returns binary audio directly
        {:ok, %{audio_blob: audio_blob, total_duration: duration}}

      {:ok, %{status: 200, body: response}} ->
        # Try to extract audio from response if it's not binary
        extract_audio_result(response, duration)

      {:ok, %{status: status, body: body}} ->
        error_details =
          case body do
            %{"detail" => detail} when is_map(detail) -> inspect(detail)
            %{"detail" => detail} when is_binary(detail) -> detail
            %{"error" => error} -> inspect(error)
            _ -> inspect(body)
          end

        Logger.error(
          "[ElevenlabsMusicService] ElevenLabs API returned status #{status}: #{error_details}"
        )
        {:error, "API request failed with status #{status}: #{error_details}"}

      {:error, exception} ->
        Logger.error(
          "[ElevenlabsMusicService] ElevenLabs API request failed: #{inspect(exception, pretty: true)}"
        )
        {:error, Exception.message(exception)}
    end
  end

  defp build_audio_prompt(scene, options) do
    # Check if a custom prompt is provided
    custom_prompt = Map.get(options, :prompt)

    if custom_prompt do
      custom_prompt
    else
      # Build prompt from scene data
      music_desc = scene["music_description"] || scene["description"] || "cinematic music"
      style = scene["music_style"] || "cinematic, piano-focused, smooth"
      energy = scene["music_energy"] || "medium-high"

      "#{music_desc}. Style: #{style}. Energy: #{energy}. Instrumental, #{@bpm} BPM"
    end
  end

  defp extract_audio_result(response, duration) do
    # Try to extract audio from various response formats
    cond do
      is_binary(response) ->
        {:ok, %{audio_blob: response, total_duration: duration}}

      is_map(response) and Map.has_key?(response, "audio") ->
        audio_data = Map.get(response, "audio")
        if is_binary(audio_data) do
          {:ok, %{audio_blob: audio_data, total_duration: duration}}
        else
          {:error, "Audio data is not binary"}
        end

      is_map(response) and Map.has_key?(response, "audio_url") ->
        # Download audio from URL
        audio_url = Map.get(response, "audio_url")
        download_audio_from_url(audio_url, duration)

      true ->
        {:error, "Unexpected response format: #{inspect(response)}"}
    end
  end

  defp download_audio_from_url(url, duration) do
    Logger.info("[ElevenlabsMusicService] Downloading audio from URL: #{url}")

    case Req.get(url, decode_body: false, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
        {:ok, %{audio_blob: audio_blob, total_duration: duration}}

      {:ok, %{status: status}} ->
        {:error, "Failed to download audio: HTTP #{status}"}

      {:error, exception} ->
        {:error, "Failed to download audio: #{Exception.message(exception)}"}
    end
  end

  defp get_api_key do
    # Try to get API key from environment variable
    System.get_env("ELEVENLABS_API_KEY")
  end

  defp create_temp_file(prefix, extension) do
    # Create a unique temporary file path
    random_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    temp_dir = System.tmp_dir!()
    Path.join(temp_dir, "#{prefix}_#{random_id}#{extension}")
  end

  defp cleanup_temp_files(file_paths) do
    # Clean up temporary files
    Enum.each(file_paths, fn path ->
      if File.exists?(path) do
        File.rm!(path)
      end
    end)
  end
end
