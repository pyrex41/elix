defmodule Backend.Services.TtsService do
  @moduledoc """
  Text-to-Speech service for generating voiceovers.

  Supports multiple TTS providers:
  - ElevenLabs (default for high quality)
  - OpenAI TTS
  - Google Cloud Text-to-Speech
  - AWS Polly

  Also includes script generation using LLM based on property details.
  """
  require Logger
  alias Backend.Services.AiService

  @doc """
  Generates voiceover audio from text script.

  ## Parameters
    - script: Text to convert to speech
    - options: Map with TTS options:
      - provider: :elevenlabs | :openai | :google | :aws_polly (default: :elevenlabs)
      - voice: Voice ID or name
      - speed: Speech speed (0.5-2.0, default: 1.0)
      - stability: Voice stability for ElevenLabs (0.0-1.0, default: 0.5)
      - similarity_boost: Voice similarity for ElevenLabs (0.0-1.0, default: 0.75)

  ## Returns
    - {:ok, audio_blob} on success
    - {:error, reason} on failure
  """
  def generate_voiceover(script, options \\ %{}) do
    provider = Map.get(options, :provider, :elevenlabs)
    Logger.info("[TtsService] Generating voiceover using #{provider}")

    case provider do
      :elevenlabs -> generate_elevenlabs(script, options)
      :openai -> generate_openai(script, options)
      :google -> generate_google(script, options)
      :aws_polly -> generate_aws_polly(script, options)
      _ -> {:error, "Unsupported TTS provider: #{provider}"}
    end
  end

  @doc """
  Generates a voiceover script using LLM based on property details and scenes.

  ## Parameters
    - property_details: Map with property information:
      - name: Property name
      - type: Property type (e.g., "luxury mountain retreat")
      - features: List of key features
      - location: Location description
    - scenes: List of scene maps
    - options: Script generation options:
      - tone: Script tone (default: "professional and engaging")
      - length: Target word count (default: based on scenes)
      - style: Script style (default: "luxury real estate")

  ## Returns
    - {:ok, %{script: full_script, segments: [scene_scripts]}} on success
    - {:error, reason} on failure
  """
  def generate_script(property_details, scenes, options \\ %{}) do
    Logger.info("[TtsService] Generating voiceover script for property")

    prompt = build_script_generation_prompt(property_details, scenes, options)

    case get_api_key() do
      nil ->
        Logger.warning("[TtsService] No API key configured, generating mock script")
        {:ok, generate_mock_script(property_details, scenes)}

      api_key ->
        call_llm_for_script(prompt, scenes, api_key)
    end
  end

  @doc """
  Generates voiceover for each scene with timing.

  Returns audio segments that can be merged with scene videos.

  ## Parameters
    - scene_scripts: List of {scene, script} tuples
    - options: TTS options

  ## Returns
    - {:ok, audio_segments} where each segment has :scene_index, :audio_blob, :duration
    - {:error, reason} on failure
  """
  def generate_scene_voiceovers(scene_scripts, options \\ %{}) do
    Logger.info("[TtsService] Generating voiceovers for #{length(scene_scripts)} scenes")

    results =
      scene_scripts
      |> Enum.with_index()
      |> Enum.map(fn {{_scene, script}, index} ->
        case generate_voiceover(script, options) do
          {:ok, audio_blob} ->
            {:ok,
             %{
               scene_index: index,
               script: script,
               audio_blob: audio_blob,
               audio_size: byte_size(audio_blob)
             }}

          {:error, reason} ->
            {:error, "Scene #{index} failed: #{reason}"}
        end
      end)

    # Check if all succeeded
    errors = Enum.filter(results, fn {status, _} -> status == :error end)

    if Enum.empty?(errors) do
      segments = Enum.map(results, fn {:ok, segment} -> segment end)
      {:ok, segments}
    else
      {:error, "Some voiceovers failed: #{inspect(errors)}"}
    end
  end

  # Private functions - Provider implementations

  defp generate_elevenlabs(script, options) do
    case get_elevenlabs_api_key() do
      nil ->
        Logger.warning("[TtsService] No ElevenLabs API key, using mock audio")
        generate_mock_audio(script)

      api_key ->
        voice_id = Map.get(options, :voice, get_default_voice(:elevenlabs))
        stability = Map.get(options, :stability, 0.5)
        similarity_boost = Map.get(options, :similarity_boost, 0.75)

        url = "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}"

        headers = [
          {"xi-api-key", api_key},
          {"Content-Type", "application/json"}
        ]

        body = %{
          "text" => script,
          "model_id" => "eleven_monolingual_v1",
          "voice_settings" => %{
            "stability" => stability,
            "similarity_boost" => similarity_boost
          }
        }

        case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
          {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
            {:ok, audio_blob}

          {:ok, %{status: status, body: body}} ->
            Logger.error("[TtsService] ElevenLabs API returned status #{status}: #{inspect(body)}")
            {:error, "API request failed with status #{status}"}

          {:error, exception} ->
            Logger.error("[TtsService] ElevenLabs API request failed: #{inspect(exception)}")
            {:error, Exception.message(exception)}
        end
    end
  end

  defp generate_openai(script, options) do
    case get_openai_api_key() do
      nil ->
        Logger.warning("[TtsService] No OpenAI API key, using mock audio")
        generate_mock_audio(script)

      api_key ->
        voice = Map.get(options, :voice, "alloy")
        speed = Map.get(options, :speed, 1.0)

        url = "https://api.openai.com/v1/audio/speech"

        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]

        body = %{
          "model" => "tts-1",
          "input" => script,
          "voice" => voice,
          "speed" => speed
        }

        case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
          {:ok, %{status: 200, body: audio_blob}} when is_binary(audio_blob) ->
            {:ok, audio_blob}

          {:ok, %{status: status, body: body}} ->
            Logger.error("[TtsService] OpenAI API returned status #{status}: #{inspect(body)}")
            {:error, "API request failed with status #{status}"}

          {:error, exception} ->
            Logger.error("[TtsService] OpenAI API request failed: #{inspect(exception)}")
            {:error, Exception.message(exception)}
        end
    end
  end

  defp generate_google(script, _options) do
    # Stub for Google Cloud TTS
    Logger.warning("[TtsService] Google TTS not yet implemented, using mock audio")
    generate_mock_audio(script)
  end

  defp generate_aws_polly(script, _options) do
    # Stub for AWS Polly
    Logger.warning("[TtsService] AWS Polly not yet implemented, using mock audio")
    generate_mock_audio(script)
  end

  defp generate_mock_audio(script) do
    # Generate silent audio as mock
    duration = estimate_duration_from_script(script)

    temp_output = create_temp_file("mock_audio", ".mp3")

    try do
      args = [
        "-f",
        "lavfi",
        "-i",
        "anullsrc=r=44100:cl=mono",
        "-t",
        to_string(duration),
        "-q:a",
        "9",
        "-acodec",
        "libmp3lame",
        temp_output
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          audio_blob = File.read!(temp_output)
          {:ok, audio_blob}

        {output, exit_code} ->
          Logger.error("[TtsService] FFmpeg mock audio failed (exit #{exit_code}): #{output}")
          {:error, "Failed to generate mock audio"}
      end
    rescue
      e ->
        Logger.error("[TtsService] Exception: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_output])
    end
  end

  # Script generation helpers

  defp build_script_generation_prompt(property_details, scenes, options) do
    tone = Map.get(options, :tone, "professional and engaging")
    style = Map.get(options, :style, "luxury real estate")

    property_name = Map.get(property_details, :name, "this property")
    property_type = Map.get(property_details, :type, "luxury property")
    features = Map.get(property_details, :features, [])
    location = Map.get(property_details, :location, "")

    scene_descriptions =
      scenes
      |> Enum.with_index(1)
      |> Enum.map(fn {scene, idx} ->
        "Scene #{idx}: #{scene["title"]} - #{scene["description"]}"
      end)
      |> Enum.join("\n")

    """
    Generate a voiceover script for a #{style} video showcasing #{property_name}.

    Property Type: #{property_type}
    Location: #{location}
    Key Features: #{Enum.join(features, ", ")}

    Video Scenes:
    #{scene_descriptions}

    Requirements:
    - Tone: #{tone}
    - Length: #{length(scenes)} segments (one per scene)
    - Each segment should be 2-4 sentences
    - Focus on emotional connection and luxury lifestyle
    - Highlight unique features naturally
    - Use cinematic language

    Return JSON with this structure:
    {
      "full_script": "Complete script as one paragraph",
      "segments": [
        {"scene": 1, "script": "Script for scene 1"},
        {"scene": 2, "script": "Script for scene 2"}
      ]
    }
    """
  end

  defp call_llm_for_script(prompt, scenes, api_key) do
    url = "https://api.x.ai/v1/chat/completions"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            "You are a professional luxury real estate scriptwriter. Generate engaging voiceover scripts for property showcase videos."
        },
        %{
          "role" => "user",
          "content" => prompt
        }
      ],
      "model" => "grok-4-1-fast-non-reasoning",
      "stream" => false,
      "temperature" => 0.7
    }

    case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_script_response(response_body, scenes)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[TtsService] Script generation API returned status #{status}: #{inspect(body)}")
        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[TtsService] Script generation failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp parse_script_response(response_body, scenes) do
    try do
      content =
        response_body
        |> Map.get("choices", [])
        |> List.first()
        |> Map.get("message", %{})
        |> Map.get("content", "")

      # Try to extract JSON from response
      case Regex.run(~r/\{[\s\S]*\}/, content) do
        [json_str] ->
          case Jason.decode(json_str) do
            {:ok, script_data} ->
              {:ok, script_data}

            _ ->
              {:error, "Failed to parse script JSON"}
          end

        _ ->
          {:error, "No JSON found in response"}
      end
    rescue
      e ->
        Logger.error("[TtsService] Failed to parse script response: #{inspect(e)}")
        {:error, "Failed to parse response"}
    end
  end

  defp generate_mock_script(property_details, scenes) do
    property_name = Map.get(property_details, :name, "This exceptional property")

    segments =
      scenes
      |> Enum.with_index(1)
      |> Enum.map(fn {scene, idx} ->
        %{
          "scene" => idx,
          "script" => "Discover the beauty of #{scene["title"]}. #{property_name} offers unparalleled luxury."
        }
      end)

    full_script =
      segments
      |> Enum.map(& &1["script"])
      |> Enum.join(" ")

    %{
      "full_script" => full_script,
      "segments" => segments
    }
  end

  # Helper functions

  defp estimate_duration_from_script(script) do
    # Rough estimate: 150 words per minute = 2.5 words per second
    word_count = String.split(script) |> length()
    max(word_count / 2.5, 1.0)
  end

  defp get_api_key do
    Application.get_env(:backend, :xai_api_key)
  end

  defp get_elevenlabs_api_key do
    Application.get_env(:backend, :elevenlabs_api_key)
  end

  defp get_openai_api_key do
    Application.get_env(:backend, :openai_api_key)
  end

  defp get_default_voice(:elevenlabs), do: "21m00Tcm4TlvDq8ikWAM"
  # Rachel voice
  defp get_default_voice(:openai), do: "alloy"
  defp get_default_voice(_), do: "default"

  defp create_temp_file(prefix, extension) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}#{extension}")
  end

  defp cleanup_temp_files(paths) do
    Enum.each(paths, fn path ->
      File.rm(path)
    end)
  end
end
