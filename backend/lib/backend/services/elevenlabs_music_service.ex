defmodule Backend.Services.ElevenlabsMusicService do
  @moduledoc """
  Service module for interacting with ElevenLabs Music API.
  Handles audio generation for video scenes with continuation support.
  """
  require Logger

  @elevenlabs_api_url "https://api.elevenlabs.io/v1/music/compose"

  @doc """
  Generates audio for a single scene using ElevenLabs Music API.

  ## Parameters
    - scene: Map containing scene description and parameters
    - options: Map with optional parameters:
      - duration: Audio duration in seconds (default: from scene)
      - prompt: Text description for music generation (default: from scene)

  ## Returns
    - {:ok, %{audio_blob: binary, total_duration: float}} on success
    - {:error, reason} on failure
  """
  def generate_scene_audio(scene, options \\ %{}) do
    case get_api_key() do
      nil ->
        Logger.info("[ElevenlabsMusicService] No ElevenLabs API key configured, using silence")
        generate_silence(scene, options)

      api_key ->
        scene_title = scene["title"] || "Unknown"
        Logger.info(
          "[ElevenlabsMusicService] Generating audio for scene: #{scene_title} (API key present: #{
            String.slice(api_key, 0, 10)
          }...)"
        )
        call_elevenlabs_api(scene, options, api_key)
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
    # ElevenLabs continuation: generate NEW audio that continues from previous
    # The continuation should create a NEW segment, not repeat the previous one
    scene_duration = Map.get(options, :duration, scene["duration"] || 4.0)
    
    # Build continuation prompt that references the previous section
    continuation_prompt = build_continuation_prompt(scene, options, previous_audio.total_duration)
    
    continuation_options =
      options
      |> Map.put(:prompt, continuation_prompt)
      |> Map.put(:duration, scene_duration)
      |> Map.put(:continuation_mode, true)

    Logger.info(
      "[ElevenlabsMusicService] Generating NEW continuation audio (#{scene_duration}s) from previous (#{previous_audio.total_duration}s)"
    )

    # Generate NEW audio segment (not merging - just the new part)
    case generate_scene_audio(scene, continuation_options) do
      {:ok, new_audio} ->
        # Return just the new audio segment - we'll merge with crossfade later
        Logger.info("[ElevenlabsMusicService] Generated new continuation segment: #{new_audio.total_duration}s")
        {:ok, new_audio}

      error ->
        error
    end
  end

  defp build_continuation_prompt(scene, options, previous_duration) do
    # Build a prompt that explicitly asks for NEW music that continues from previous
    # NO FADE INSTRUCTIONS - maintain continuous energy
    base_prompt = Map.get(options, :prompt) || build_audio_prompt(scene, options)
    
    # Add explicit continuation instruction with NO fade
    "#{base_prompt}. This is a NEW section starting at #{previous_duration}s. Continue the musical theme from the previous section but create NEW musical content. Maintain tempo (120 BPM) and FULL energy level throughout. NO fade in or fade out. Continuous, steady energy from start to finish. Smooth transition."
  end

  @doc """
  Generates a complete music track for multiple scenes using continuation.

  This function generates audio for each scene sequentially, using continuation
  to create a seamless audio experience across all scenes.

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

    Logger.info(
      "[ElevenlabsMusicService] Generating music for #{length(scenes)} scenes using 3-chunk approach (12s + 12s + 4s = 28s total)"
    )

    # Use 3-chunk approach: 12s (scenes 1-3), 12s (scenes 4-6), 10s trimmed to 4s (scene 7)
    # This reduces API calls and improves continuity while maintaining 4-second sync
    generate_music_3chunk(scenes, default_duration, options)
  end

  defp _generate_music_for_scenes_sequential(scenes, options) do
    default_duration = Map.get(options, :default_duration, 4.0)

    Logger.info(
      "[ElevenlabsMusicService] Generating music sequentially for #{length(scenes)} scenes with continuation"
    )

    # Generate audio for each scene with continuation
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
                "[ElevenlabsMusicService] Scene 1: Generating initial audio (duration: #{scene_duration}s, no continuation)"
              )
              scene_opts = Map.merge(%{duration: scene_duration, is_last_scene: is_last_scene}, options)
              generate_scene_audio(scene, scene_opts)

            prev ->
              # Subsequent scenes: use continuation
              scene_num = scene_index + 1
              cumulative_duration = prev.total_duration + scene_duration

              Logger.info(
                "[ElevenlabsMusicService] Scene #{scene_num}: Using continuation from previous audio (#{prev.total_duration}s), generating #{scene_duration}s more (total: #{cumulative_duration}s)#{if is_last_scene, do: " [LAST SCENE - will fade]", else: ""}"
              )

              continuation_opts = Map.merge(%{duration: scene_duration, is_last_scene: is_last_scene}, options)
              generate_with_continuation(scene, prev, continuation_opts)
          end

        case scene_result do
          {:ok, new_audio_data} ->
            new_duration = Map.get(new_audio_data, :total_duration, scene_duration)
            cumulative = %{
              audio_blob: new_audio_data.audio_blob,
              total_duration: new_duration
            }
            Logger.info(
              "[ElevenlabsMusicService] Scene #{scene_index + 1} complete: cumulative audio = #{new_duration}s"
            )
            {:cont, {:ok, cumulative}}

          {:error, reason} ->
            {:halt, {:error, "Failed to generate audio for scene: #{reason}"}}
        end
      end)

    case result do
      {:ok, final_cumulative} ->
        # Return the final cumulative audio
        {:ok, final_cumulative.audio_blob}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_music_3chunk(scenes, _default_duration, options) do
    # Generate 36 seconds of audio (extra buffer), then trim and fade to 28s
    # This ensures no early fade from ElevenLabs - we control the fade with FFmpeg
    # Used by both "ElevenLabs 3-Chunk" and "ElevenLabs 28s (Seamless Segues)" buttons
    Logger.info("[ElevenlabsMusicService] Generating 36s track (will trim to 28s with fade at 26-28s)")
    
    # Use consistent seed
    seed = Map.get(options, :seed, :erlang.phash2(scenes) |> rem(4294967295))
    Logger.info("[ElevenlabsMusicService] Using seed: #{seed}")
    
    # Build a single comprehensive prompt with all scenes and timestamps
    # NO fade instructions - we'll handle fade with FFmpeg
    # 120 BPM = 2 beats per second = 8 beats per 4 seconds (perfect for scene changes)
    combined_prompt = build_28s_prompt_with_timestamps(scenes)
    
    # Create a single scene map for 36-second generation (extra buffer)
    full_scene = %{
      "title" => "Complete 28-Second Track",
      "description" => "Luxury vacation getaway showcase",
      "duration" => 36.0,  # Generate 36s to have buffer
      "music_description" => combined_prompt,
      "music_style" => "cinematic, piano-focused, smooth",
      "music_energy" => "medium-high"
    }
    
    # Generate 36-second track using simple compose endpoint (not composition plan)
    generate_options = 
      options
      |> Map.put(:duration, 36.0)  # Generate 36s
      |> Map.put(:prompt, combined_prompt)
      |> Map.put(:seed, seed)
    
    case get_api_key() do
      nil ->
        Logger.info("[ElevenlabsMusicService] No ElevenLabs API key configured")
        {:error, "No API key configured"}

      api_key ->
        Logger.info("[ElevenlabsMusicService] Generating 36s track with single prompt (all 7 scenes, no fade instructions, 120 BPM for 4s beats)")
        case call_elevenlabs_api_simple(full_scene, generate_options, api_key) do
          {:ok, %{audio_blob: audio_blob}} ->
            # Trim to 28s and apply fade out only at 26-28s (last 2 seconds) using FFmpeg
            # This ensures no early fade - we have full control
            trim_and_fade_to_28s(audio_blob, 26.0, 2.0)
          
          error ->
            error
        end
    end
  end
  
  defp build_28s_prompt_with_timestamps(scenes) do
    # Build a prompt with all scenes and explicit timestamps for scene changes
    scene_descriptions = 
      scenes
      |> Enum.with_index()
      |> Enum.map(fn {scene, index} ->
        start_time = index * 4
        end_time = (index + 1) * 4
        scene_desc = scene["music_description"] || scene["description"] || ""
        scene_title = scene["title"] || "Scene #{index + 1}"
        "#{start_time}-#{end_time}s: #{scene_title} - #{scene_desc}"
      end)
      |> Enum.join(". ")
    
    base_style = "luxury vacation getaway, cinematic, piano-focused, smooth, medium-high energy"
    
    # 120 BPM = 2 beats per second = 8 beats per 4 seconds
    # This creates perfect alignment with 4-second scene changes
    "#{base_style}. 36-second instrumental track with clear scene transitions every 4 seconds. #{scene_descriptions}. 120 BPM (2 beats per second, 8 beats per 4-second scene change) with strong beat markers at 0s, 4s, 8s, 12s, 16s, 20s, 24s, 28s. CRITICAL: Maintain FULL energy and volume throughout the entire track. NO fade in. NO fade out. NO volume reduction. Keep constant, steady energy from start to finish. Smooth, flowing transitions between scenes. Instrumental, piano-focused."
  end
  
  defp call_elevenlabs_api_simple(scene, options, api_key) do
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

    # Req needs to be told to expect binary response (not JSON)
    # Add timeout for long requests (28 seconds of music generation can take 60-90 seconds)
    case Req.post(@elevenlabs_api_url, json: body, headers: headers, decode_body: false, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
        # ElevenLabs returns binary audio directly
        # Return as audio_blob format for consistency
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
  
  defp generate_with_composition_plan_segue(composition_plan, seed, options) do
    case get_api_key() do
      nil ->
        Logger.info("[ElevenlabsMusicService] No ElevenLabs API key configured")
        {:error, "No API key configured"}

      api_key ->
        Logger.info(
          "[ElevenlabsMusicService] Generating cohesive track with composition plan (#{length(composition_plan["sections"])} sections, seed: #{seed})"
        )
        call_elevenlabs_compose_with_segue(composition_plan, seed, options, api_key)
    end
  end
  
  defp call_elevenlabs_compose_with_segue(composition_plan, seed, options, api_key) do
    # Calculate total duration for logging (but don't send it - API calculates from composition_plan)
    total_duration_ms = 
      composition_plan["sections"]
      |> Enum.map(& &1["duration_ms"])
      |> Enum.sum()
    
    # Build request body for compose endpoint with composition_plan
    # This generates a single cohesive track with seamless segues between sections
    # Note: music_length_ms should NOT be included when using composition_plan
    body = %{
      composition_plan: composition_plan,
      output_format: "mp3_44100_128",
      force_instrumental: true,
      seed: seed
    }
    
    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    Logger.info(
      "[ElevenlabsMusicService] Calling ElevenLabs compose API with composition plan: #{total_duration_ms}ms total, #{length(composition_plan["sections"])} sections"
    )

    case Req.post(@elevenlabs_api_url, json: body, headers: headers, decode_body: false) do
      {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
        # ElevenLabs returns binary audio directly - this is already a cohesive track with segues
        Logger.info("[ElevenlabsMusicService] Successfully generated cohesive track with seamless segues (#{total_duration_ms}ms)")
        {:ok, audio_blob}

      {:ok, %{status: status, body: body}} ->
        error_details =
          case body do
            %{"detail" => detail} when is_map(detail) -> inspect(detail)
            %{"detail" => detail} when is_binary(detail) -> detail
            %{"error" => error} -> inspect(error)
            _ -> inspect(body)
          end

        Logger.error(
          "[ElevenlabsMusicService] ElevenLabs compose API returned status #{status}: #{error_details}"
        )
        {:error, "API request failed with status #{status}: #{error_details}"}

      {:error, exception} ->
        Logger.error(
          "[ElevenlabsMusicService] ElevenLabs compose API request failed: #{inspect(exception, pretty: true)}"
        )
        {:error, Exception.message(exception)}
    end
  end
  
  defp trim_and_fade_to_28s(audio_blob, fade_start_sec, fade_duration_sec) do
    # Trim to 28s and apply fade out only at 26-28s (last 2 seconds)
    # This gives us full control - no early fade from ElevenLabs
    temp_input_path = create_temp_file("input_audio", ".mp3")
    temp_output_path = create_temp_file("trimmed_faded_audio", ".mp3")

    try do
      File.write!(temp_input_path, audio_blob)

      # First trim to 28s, then apply fade from 26-28s
      # The fade will be applied during the trim operation
      filter_complex = "[0:a]atrim=0:28,asetpts=PTS-STARTPTS,afade=t=out:st=#{fade_start_sec}:d=#{fade_duration_sec}[out]"
      
      args = [
        "-i", temp_input_path,
        "-filter_complex", filter_complex,
        "-map", "[out]",
        "-t", "28",  # Ensure exactly 28 seconds
        "-q:a", "2",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          final_blob = File.read!(temp_output_path)
          Logger.info("[ElevenlabsMusicService] Trimmed to 28s and applied fade out at #{fade_start_sec}-#{fade_start_sec + fade_duration_sec}s")
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

  defp apply_final_fade(audio_blob, fade_start_sec, fade_duration_sec) do
    # Apply fade out only at the very end (26-28s)
    temp_input_path = create_temp_file("input_audio", ".mp3")
    temp_output_path = create_temp_file("faded_audio", ".mp3")

    try do
      File.write!(temp_input_path, audio_blob)

      filter_complex = "[0:a]afade=t=out:st=#{fade_start_sec}:d=#{fade_duration_sec}[out]"
      
      args = [
        "-i", temp_input_path,
        "-filter_complex", filter_complex,
        "-map", "[out]",
        "-q:a", "2",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          faded_blob = File.read!(temp_output_path)
          Logger.info("[ElevenlabsMusicService] Applied final fade out at #{fade_start_sec}-#{fade_start_sec + fade_duration_sec}s")
          {:ok, faded_blob}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] Fade failed (exit #{exit_code}): #{output}")
          {:error, "Fade failed"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during fade: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_input_path, temp_output_path])
    end
  end

  defp generate_chunk(scenes, duration, prompt, seed, previous_audio, options) do
    # Generate a chunk - each chunk generates its own unique audio
    # We generate longer than needed and cut to avoid fade artifacts
    combined_scene = build_combined_scene(scenes, prompt)
    
    chunk_options = 
      options
      |> Map.put(:duration, duration)
      |> Map.put(:prompt, prompt)
      |> Map.put(:seed, seed)  # Same seed for all chunks
    
    case previous_audio do
      nil ->
        # First chunk: no continuation, generate fresh audio
        Logger.info("[ElevenlabsMusicService] Generating chunk 1 (#{duration}s) - unique audio, seed: #{seed}")
        generate_scene_audio(combined_scene, chunk_options)
      
      prev ->
        # Subsequent chunks: generate NEW unique audio that continues from previous
        Logger.info("[ElevenlabsMusicService] Generating chunk (#{duration}s) - NEW unique audio continuing from previous (#{prev.total_duration}s), seed: #{seed}")
        
        # Build continuation prompt that explicitly asks for NEW content with NO fades
        continuation_prompt = "#{prompt}. This is a NEW section starting after #{prev.total_duration}s. Create NEW musical content that continues the theme from the previous section. Maintain tempo (120 BPM) and FULL energy throughout. NO fade in or fade out. Continuous, steady energy. Smooth transition but with fresh musical ideas."
        
        continuation_options = 
          chunk_options
          |> Map.put(:prompt, continuation_prompt)
          |> Map.put(:continuation_mode, true)
        
        # Generate NEW audio segment
        generate_scene_audio(combined_scene, continuation_options)
    end
  end

  defp build_combined_scene(scenes, prompt) do
    # Build a combined scene from multiple scenes for chunk generation
    first_scene = List.first(scenes) || %{}
    
    %{
      "title" => Enum.map(scenes, & &1["title"]) |> Enum.join(" + "),
      "description" => prompt,
      "duration" => Enum.sum(Enum.map(scenes, fn s -> s["duration"] || 4.0 end)),
      "music_description" => Enum.map(scenes, fn s -> s["music_description"] || "" end) |> Enum.join(". "),
      "music_style" => first_scene["music_style"] || "cinematic, piano-focused, smooth",
      "music_energy" => first_scene["music_energy"] || "medium-high"
    }
  end

  defp build_chunk_prompt(scenes, chunk_name, is_outro) do
    # Build a combined prompt for multiple scenes in one chunk
    # NO FADE INSTRUCTIONS - we want continuous energy throughout
    scene_descriptions = 
      scenes
      |> Enum.map(fn scene ->
        desc = scene["music_description"] || scene["description"] || ""
        title = scene["title"] || ""
        "#{title}: #{desc}"
      end)
      |> Enum.join(". ")
    
    base = "luxury vacation getaway, cinematic, piano-focused, smooth, medium-high energy"
    
    # Explicitly avoid fades - maintain continuous energy
    no_fade_instruction = if is_outro do
      "Maintain full energy and volume throughout. NO fade out. Keep the same energy level until the very end"
    else
      "Maintain full energy and volume throughout. NO fade in or fade out. Continuous, steady energy. Keep the same energy level from start to finish"
    end
    
    "#{chunk_name} section (#{length(scenes)} scenes): #{base}. #{scene_descriptions}. 120 BPM with clear beat markers every 4 seconds. Instrumental, flowing. #{no_fade_instruction}. Smooth continuation with consistent energy"
  end

  defp merge_with_crossfades(chunk1_blob, chunk2_blob, chunk3_blob) do
    # Merge all 3 chunks with 2-second overlapping crossfades (blend) - no silence between chunks
    # True crossfade: overlap segments and mix them together during the transition
    # Chunk 1 (12s) -> 2s blend -> Chunk 2 (12s) -> 2s blend -> Chunk 3 (4s)
    # Fade out ONLY at 26-28 seconds (last 2 seconds of chunk 3)
    temp_chunk1_path = create_temp_file("chunk1", ".mp3")
    temp_chunk2_path = create_temp_file("chunk2", ".mp3")
    temp_chunk3_path = create_temp_file("chunk3", ".mp3")
    temp_final_path = create_temp_file("final", ".mp3")

    try do
      File.write!(temp_chunk1_path, chunk1_blob)
      File.write!(temp_chunk2_path, chunk2_blob)
      File.write!(temp_chunk3_path, chunk3_blob)

      # True crossfade with overlap and mixing (blend) - no silence between chunks
      # Strategy: Overlap segments and mix them during the transition period
      # - Chunk 1: 12s total, fade out last 2s (10-12s absolute)
      # - Chunk 2: Delay to start at 10s (overlapping with chunk 1), fade in first 2s (0-2s relative = 10-12s absolute), 
      #            fade out last 2s (10-12s relative = 22-24s absolute)
      # - Chunk 3: Delay to start at 22s (overlapping with chunk 2), fade in first 2s (0-2s relative = 22-24s absolute),
      #            fade out last 2s (2-4s relative = 24-26s absolute, but we want 26-28s, so use 4-6s relative)
      # Use amix to blend overlapping segments with proper normalization
      crossfade_duration = 2.0  # 2 second crossfade/blend
      delay_chunk2_ms = 10000  # Start chunk 2 at 10 seconds (overlapping with chunk 1's fade)
      delay_chunk3_ms = 22000  # Start chunk 3 at 22 seconds (overlapping with chunk 2's fade)
      
      filter_complex = """
      [0:a]atrim=0:12,asetpts=PTS-STARTPTS,afade=t=out:st=10:d=#{crossfade_duration}[a0];
      [1:a]atrim=0:12,asetpts=PTS-STARTPTS,adelay=#{delay_chunk2_ms}|#{delay_chunk2_ms},afade=t=in:st=0:d=#{crossfade_duration},afade=t=out:st=10:d=#{crossfade_duration}[a1];
      [2:a]atrim=0:4,asetpts=PTS-STARTPTS,adelay=#{delay_chunk3_ms}|#{delay_chunk3_ms},afade=t=in:st=0:d=#{crossfade_duration},afade=t=out:st=4:d=2[a2];
      [a0][a1][a2]amix=inputs=3:duration=longest:normalize=0:dropout_transition=0[out]
      """
      
      final_args = [
        "-i", temp_chunk1_path,
        "-i", temp_chunk2_path,
        "-i", temp_chunk3_path,
        "-filter_complex", String.trim(filter_complex),
        "-map", "[out]",
        "-t", "28",  # Ensure exactly 28 seconds
        "-q:a", "2",
        temp_final_path
      ]

      case System.cmd("ffmpeg", final_args, stderr_to_stdout: true) do
        {_output, 0} ->
          final_blob = File.read!(temp_final_path)
          Logger.info("[ElevenlabsMusicService] Successfully merged 3 chunks with 2s overlapping crossfades (blend) and fade out at 26-28s (28s total)")
          {:ok, final_blob}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] Crossfade merge failed (exit #{exit_code}): #{output}")
          {:error, "Crossfade merge failed"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during crossfade merge: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([
        temp_chunk1_path, temp_chunk2_path, temp_chunk3_path,
        temp_final_path
      ])
    end
  end

  defp _build_composition_plan(scenes, default_duration) do
    # Build composition plan with 7 sections of 4 seconds each (28 seconds total)
    # Each section corresponds to a scene, ensuring perfect sync with scene changes
    # Use consistent base style and continuity language to ensure smooth flow
    
    # Extract base style from first scene to maintain consistency
    base_style = _extract_base_style(scenes)
    
    sections =
      scenes
      |> Enum.with_index()
      |> Enum.map(fn {scene, index} ->
        scene_duration = scene["duration"] || default_duration
        duration_ms = round(scene_duration * 1000)
        is_last_scene = (index + 1) == length(scenes)
        
        # Build prompt with continuity references and consistent base style
        prompt = build_section_prompt_with_continuity(scene, base_style, index, is_last_scene, length(scenes))
        
        %{
          "name" => scene["title"] || "Scene #{index + 1}",
          "duration_ms" => duration_ms,
          "prompt" => prompt
        }
      end)

    %{
      "sections" => sections
    }
  end

  defp _extract_base_style(scenes) do
    # Extract common style elements from all scenes to maintain consistency
    first_scene = List.first(scenes)
    
    case {first_scene["music_style"], first_scene["music_energy"]} do
      {style, energy} when not is_nil(style) and not is_nil(energy) ->
        %{style: style, energy: energy, base: "luxury vacation getaway"}
      
      _ ->
        %{style: "cinematic, piano-focused, smooth", energy: "medium-high", base: "luxury vacation getaway"}
    end
  end

  defp build_section_prompt_with_continuity(scene, base_style, index, is_last_scene, _total_sections) do
    # Build prompt in the format shown in ElevenLabs UI: "0-4s Hook: ... 4-8s Bedroom: ..."
    # This format helps ElevenLabs understand the time-based structure
    
    scene_desc = scene["music_description"] || scene["description"] || ""
    scene_title = scene["title"] || "Scene #{index + 1}"
    
    # Calculate time range for this section (0-4s, 4-8s, 8-12s, etc.)
    start_time_sec = index * 4
    end_time_sec = (index + 1) * 4
    
    # Base style elements
    base_elements = "#{base_style.base}, #{base_style.style}, #{base_style.energy}"
    
    # Build section-specific prompt
    section_desc = 
      cond do
        index == 0 ->
          # First section: establish foundation
          "#{scene_desc}. Establish main theme, 120 BPM, clear beat markers every 4 seconds"
        
        is_last_scene ->
          # Last section: gentle conclusion
          "#{scene_desc}. Smoothly continue from previous, maintaining tempo and energy. Gentle fade out"
        
        true ->
          # Middle sections: smooth transitions
          "#{scene_desc}. Smoothly continue from previous, maintaining consistent tempo (120 BPM), energy, and theme. Seamless transition"
      end
    
    # Format like ElevenLabs UI: "0-4s Hook: description..."
    "#{start_time_sec}-#{end_time_sec}s #{scene_title}: #{base_elements}. #{section_desc}. Instrumental, piano-focused, flowing. Beat marker at #{end_time_sec}s"
    |> String.trim()
    |> String.replace(~r/\s+/, " ")  # Normalize whitespace
  end

  defp _generate_with_composition_plan(composition_plan, options) do
    case get_api_key() do
      nil ->
        Logger.info("[ElevenlabsMusicService] No ElevenLabs API key configured")
        {:error, "No API key configured"}

      api_key ->
        Logger.info(
          "[ElevenlabsMusicService] Generating music with composition plan (#{length(composition_plan["sections"])} sections)"
        )
        _call_elevenlabs_compose_with_plan(composition_plan, options, api_key)
    end
  end

  defp _call_elevenlabs_compose_with_plan(composition_plan, options, api_key) do
    # Use a consistent seed for all sections to ensure musical consistency and flow
    # Seed helps maintain similar style, tempo, and instrumentation across sections
    seed = Map.get(options, :seed, :erlang.phash2(composition_plan) |> rem(4294967295))
    
    # Build request body for compose endpoint with composition_plan
    # This generates ONE 28-second track with all 7 sections defined
    body = %{
      composition_plan: composition_plan,
      output_format: "mp3_44100_128",
      respect_sections_durations: true,  # Ensure exact 4-second timing for scene sync
      seed: seed  # Use same seed for consistency across all sections
    }

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    total_duration_ms = 
      composition_plan["sections"]
      |> Enum.reduce(0, fn section, acc -> acc + section["duration_ms"] end)

    Logger.info(
      "[ElevenlabsMusicService] Calling ElevenLabs compose API with composition plan: POST #{@elevenlabs_api_url} with #{length(composition_plan["sections"])} sections, total duration: #{total_duration_ms}ms, seed: #{seed}"
    )

    case Req.post(@elevenlabs_api_url, json: body, headers: headers, decode_body: false) do
      {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
        # ElevenLabs returns binary audio directly - ONE 28-second track with all sections
        duration = total_duration_ms / 1000.0
        Logger.info("[ElevenlabsMusicService] Successfully generated #{duration}s audio with composition plan (seed: #{seed})")
        {:ok, audio_blob}

      {:ok, %{status: status, body: body}} ->
        error_details =
          case body do
            %{"detail" => detail} when is_map(detail) -> inspect(detail)
            %{"detail" => detail} when is_binary(detail) -> detail
            %{"error" => error} -> inspect(error)
            _ -> inspect(body)
          end

        Logger.error(
          "[ElevenlabsMusicService] ElevenLabs compose API returned status #{status}: #{error_details}"
        )
        {:error, "API request failed with status #{status}: #{error_details}"}

      {:error, exception} ->
        Logger.error(
          "[ElevenlabsMusicService] ElevenLabs compose API request failed: #{inspect(exception, pretty: true)}"
        )
        {:error, Exception.message(exception)}
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
    Logger.info("[ElevenlabsMusicService] Merging #{length(audio_segments)} audio segments")

    case audio_segments do
      [] ->
        {:error, "No audio segments to merge"}

      [single_segment] ->
        {:ok, single_segment}

      segments ->
        merge_with_ffmpeg(segments, fade_duration)
    end
  end

  # Private functions

  defp get_api_key do
    Application.get_env(:backend, :elevenlabs_api_key)
  end

  defp call_elevenlabs_api(scene, options, api_key) do
    # Build prompt from scene description
    prompt = build_audio_prompt(scene, options)
    duration = Map.get(options, :duration, scene["duration"] || 4.0)
    duration_ms = round(duration * 1000)

    # ElevenLabs API requires music_length_ms between 10000ms (10s) and 300000ms (5min)
    # For 4-second chunks, we need to generate at least 10 seconds, then trim to 4 seconds
    # This ensures each chunk is perfectly synced with 4-second scene changes
    music_length_ms = max(duration_ms, 10_000)

    # Build request body
    # ElevenLabs uses 'prompt' and 'music_length_ms'
    body = %{
      prompt: prompt,
      music_length_ms: music_length_ms,
      output_format: "mp3_44100_128",
      force_instrumental: true
    }

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    Logger.info(
      "[ElevenlabsMusicService] Calling ElevenLabs API: POST #{@elevenlabs_api_url} with prompt length=#{String.length(prompt)}, music_length_ms=#{music_length_ms}ms (will trim to #{duration}s)"
    )

    # Req needs to be told to expect binary response (not JSON)
    # Add timeout for long requests (music generation can take 60-90 seconds)
    case Req.post(@elevenlabs_api_url, json: body, headers: headers, decode_body: false, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
        # ElevenLabs returns binary audio directly
        # Trim to exact target duration (4 seconds for scene sync)
        trim_audio_to_duration(audio_blob, duration)

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

  defp extract_audio_result(response, expected_duration) do
    # ElevenLabs returns audio as binary or in various formats
    case response do
      audio_blob when is_binary(audio_blob) ->
        # Direct binary audio
        duration = get_audio_duration_from_blob(audio_blob)
        {:ok, %{audio_blob: audio_blob, total_duration: duration}}

      %{"audio_base64" => audio_base64} when is_binary(audio_base64) ->
        case Base.decode64(audio_base64) do
          {:ok, audio_blob} ->
            duration = get_audio_duration_from_blob(audio_blob)
            {:ok, %{audio_blob: audio_blob, total_duration: duration}}

          :error ->
            {:error, "Failed to decode base64 audio"}
        end

      %{"audio_url" => audio_url} when is_binary(audio_url) ->
        # Download audio from URL
        download_audio_from_url(audio_url, expected_duration)

      %{"audio" => audio_data} when is_binary(audio_data) ->
        # Direct audio data
        duration = get_audio_duration_from_blob(audio_data)
        {:ok, %{audio_blob: audio_data, total_duration: duration}}

      _ ->
        Logger.error("[ElevenlabsMusicService] Unexpected response format: #{inspect(response)}")
        {:error, "Invalid audio output format"}
    end
  end

  defp trim_audio_to_duration(audio_blob, target_duration) do
    # Trim audio to exact target duration using FFmpeg
    temp_input_path = create_temp_file("input_audio", ".mp3")
    temp_output_path = create_temp_file("trimmed_audio", ".mp3")

    try do
      File.write!(temp_input_path, audio_blob)

      args = [
        "-i", temp_input_path,
        "-t", to_string(target_duration),
        "-c", "copy",  # Stream copy for speed
        "-y",  # Overwrite output
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          trimmed_blob = File.read!(temp_output_path)
          {:ok, %{audio_blob: trimmed_blob, total_duration: target_duration}}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] FFmpeg trim failed (exit #{exit_code}): #{output}")
          # Fallback: return original audio
          duration = get_audio_duration_from_blob(audio_blob)
          {:ok, %{audio_blob: audio_blob, total_duration: duration}}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during trim: #{inspect(e)}")
        # Fallback: return original audio
        duration = get_audio_duration_from_blob(audio_blob)
        {:ok, %{audio_blob: audio_blob, total_duration: duration}}
    after
      cleanup_temp_files([temp_input_path, temp_output_path])
    end
  end

  defp download_audio_from_url(audio_url, _expected_duration) do
    case Req.get(audio_url) do
      {:ok, %{status: 200, body: audio_blob}} ->
        duration = get_audio_duration_from_blob(audio_blob)
        {:ok, %{audio_blob: audio_blob, total_duration: duration}}

      {:error, exception} ->
        Logger.error("[ElevenlabsMusicService] Failed to download audio: #{inspect(exception)}")
        {:error, "Failed to download generated audio"}
    end
  end

  defp _merge_continuation_audio(previous_audio_blob, new_audio_blob, total_duration) do
    # Merge two audio blobs using FFmpeg with crossfade
    temp_prev_path = create_temp_file("prev_audio", ".mp3")
    temp_new_path = create_temp_file("new_audio", ".mp3")
    temp_output_path = create_temp_file("merged", ".mp3")

    try do
      File.write!(temp_prev_path, previous_audio_blob)
      File.write!(temp_new_path, new_audio_blob)

      # Use FFmpeg to concatenate with crossfade
      # Simple concatenation for now - can add crossfade later if needed
      ffmpeg_args = [
        "-i", temp_prev_path,
        "-i", temp_new_path,
        "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1[out]",
        "-map", "[out]",
        "-q:a", "2",
        temp_output_path
      ]

      case System.cmd("ffmpeg", ffmpeg_args, stderr_to_stdout: true) do
        {_output, 0} ->
          merged_blob = File.read!(temp_output_path)
          {:ok, %{audio_blob: merged_blob, total_duration: total_duration}}

        {output, exit_code} ->
          Logger.error("[ElevenlabsMusicService] FFmpeg merge failed (exit #{exit_code}): #{output}")
          {:error, "FFmpeg merge failed"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during merge: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_prev_path, temp_new_path, temp_output_path])
    end
  end

  defp build_audio_prompt(scene, options) do
    # Use provided prompt or build from scene
    Map.get(options, :prompt) || build_prompt_from_scene(scene, options)
  end

  defp build_prompt_from_scene(scene, options) do
    # Check if this is the last scene (for fade instructions)
    is_last_scene = Map.get(options, :is_last_scene, false)
    continuation_mode = Map.get(options, :continuation_mode, false)

    # Check if scene has template-based music metadata
    case {scene["music_description"], scene["music_style"], scene["music_energy"]} do
      {desc, style, energy} when not is_nil(desc) and not is_nil(style) ->
        # Use template-based music prompt
        build_template_music_prompt(desc, style, energy, is_last_scene, continuation_mode)

      _ ->
        # Fallback to legacy scene description analysis
        build_legacy_music_prompt(scene, is_last_scene, continuation_mode)
    end
  end

  defp build_template_music_prompt(description, style, energy, _is_last_scene, continuation_mode) do
    # ElevenLabs prompt with 4-second beat sync instruction
    # NO FADE INSTRUCTIONS - we want continuous energy
    base_prompt = "Upbeat piano music, luxury vacation getaway, #{description}. #{style}, #{energy}. Instrumental, cinematic, piano-focused, smooth and flowing. 120 BPM tempo with clear beat markers every 4 seconds for scene synchronization"

    continuation_text = if continuation_mode do
      ". Seamlessly continue from previous segment, maintaining tempo and FULL energy. NO fade in or fade out. Continuous, steady energy throughout"
    else
      ". Maintain FULL energy and volume throughout. NO fade in or fade out. Continuous, steady energy from start to finish"
    end

    # NO fade instruction - we'll add fade only at 26-28s in post-processing
    energy_instruction = ". Keep the same energy level throughout. NO fade to silence"

    (base_prompt <> continuation_text <> energy_instruction)
    |> String.trim()
  end

  defp build_legacy_music_prompt(scene, _is_last_scene, continuation_mode) do
    # Extract mood and style from scene description (legacy method)
    # NO FADE INSTRUCTIONS - continuous energy only
    description = scene["description"] || ""

    base_prompt = "Upbeat piano music, luxury vacation getaway. 120 BPM tempo with clear beat markers every 4 seconds for scene synchronization"

    mood =
      cond do
        String.contains?(description, ["exciting", "dynamic", "energy"]) -> "upbeat and energetic"
        String.contains?(description, ["calm", "peaceful", "serene"]) -> "calm and peaceful"
        String.contains?(description, ["dramatic", "intense"]) -> "dramatic and intense"
        String.contains?(description, ["elegant", "luxury"]) -> "elegant and sophisticated"
        true -> "professional and engaging"
      end

    continuation_text = if continuation_mode do
      ", seamlessly continue from previous segment, maintaining FULL energy. NO fade in or fade out"
    else
      ", maintain FULL energy throughout. NO fade in or fade out"
    end

    # NO fade instruction - continuous energy only
    energy_instruction = ". Continuous, steady energy. NO fade to silence"

    "#{base_prompt}, #{mood}, instrumental, piano-focused, flowing#{continuation_text}#{energy_instruction}"
  end

  defp generate_silence(scene, options) do
    # Generate silent audio as fallback
    duration = Map.get(options, :duration, scene["duration"] || 5)

    temp_output_path = create_temp_file("silence", ".mp3")

    try do
      # Generate silence using FFmpeg
      args = [
        "-f", "lavfi",
        "-i", "anullsrc=r=44100:cl=stereo",
        "-t", to_string(duration),
        "-q:a", "9",
        "-acodec", "libmp3lame",
        temp_output_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          audio_blob = File.read!(temp_output_path)
          {:ok, %{audio_blob: audio_blob, total_duration: duration}}

        {output, exit_code} ->
          Logger.error(
            "[ElevenlabsMusicService] FFmpeg silence generation failed (exit #{exit_code}): #{output}"
          )
          {:error, "Failed to generate silence"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during silence generation: #{inspect(e)}")
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
          Logger.error("[ElevenlabsMusicService] FFmpeg merge failed (exit #{exit_code}): #{output}")
          {:error, "Failed to merge audio segments"}
      end
    rescue
      e ->
        Logger.error("[ElevenlabsMusicService] Exception during merge: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files(segment_paths ++ [temp_output_path])
    end
  end

  defp build_fade_filter(num_segments, fade_duration) do
    # Build filter complex for fading between segments
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
    # Calculate fade start time (assuming 4s default duration per segment)
    max(0, 4 - 1)
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

  defp get_media_duration(file_path) do
    args = [
      "-v", "error",
      "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1",
      file_path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {duration, _} -> {:ok, duration}
          :error -> {:error, "Invalid duration format"}
        end

      {output, _} ->
        Logger.error("[ElevenlabsMusicService] ffprobe failed: #{output}")
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

