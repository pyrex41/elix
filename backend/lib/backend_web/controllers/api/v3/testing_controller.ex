defmodule BackendWeb.Api.V3.TestingController do
  @moduledoc """
  Testing controller for AI video generation pipeline.

  Provides endpoints to test and debug individual components:
  - Scene template generation
  - Image pair selection
  - Music generation (single and multiple scenes)
  - Prompt generation
  - Asset visualization

  NOTE: These endpoints should only be available in development/staging environments.
  """
  use BackendWeb, :controller
  require Logger

  alias Backend.Services.{AiService, MusicgenService, OverlayService, TtsService}
  alias Backend.Templates.SceneTemplates
  alias Backend.Pipeline.PipelineConfig
  alias Backend.Schemas.{Campaign, Asset, Job}
  alias Backend.Repo
  import Ecto.Query

  # Helper to safely convert string keys to atom keys for known options
  defp atomize_keys(map, allowed_keys) when is_map(map) and is_list(allowed_keys) do
    Enum.reduce(allowed_keys, %{}, fn key, acc ->
      atom_key = if is_binary(key), do: String.to_existing_atom(key), else: key
      string_key = to_string(key)

      cond do
        Map.has_key?(map, atom_key) -> Map.put(acc, atom_key, Map.get(map, atom_key))
        Map.has_key?(map, string_key) -> Map.put(acc, atom_key, Map.get(map, string_key))
        true -> acc
      end
    end)
  rescue
    ArgumentError -> %{}
  end

  @doc """
  GET /api/v3/testing/scene-templates
  Returns all scene templates with their configurations.
  """
  def scene_templates(conn, _params) do
    templates = SceneTemplates.all_templates()

    json(conn, %{
      success: true,
      count: length(templates),
      templates: templates
    })
  end

  @doc """
  POST /api/v3/testing/scene-templates/adapt
  Tests scene template adaptation.

  Body:
    {
      "scene_count": 7,
      "available_scene_types": ["exterior", "bedroom", "bathroom"]
    }
  """
  def adapt_scene_templates(conn, %{"scene_count" => scene_count} = params) do
    available_types = Map.get(params, "available_scene_types", [])
    templates = SceneTemplates.adapt_to_scene_count(scene_count, available_types)

    json(conn, %{
      success: true,
      requested_count: scene_count,
      available_types: available_types,
      adapted_templates: templates
    })
  end

  @doc """
  POST /api/v3/testing/image-selection
  Tests image pair selection for scenes.

  Body:
    {
      "campaign_id": 123,
      "scene_count": 7,
      "brief": "Luxury mountain retreat"
    }
  """
  def test_image_selection(conn, %{"campaign_id" => campaign_id} = params) do
    scene_count = Map.get(params, "scene_count", 7)
    brief = Map.get(params, "brief", "Luxury property showcase")

    case Repo.get(Campaign, campaign_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "Campaign not found"})

      campaign ->
        # Load campaign assets
        assets =
          Asset
          |> where([a], a.campaign_id == ^campaign_id and a.type == :image)
          |> Repo.all()

        if Enum.empty?(assets) do
          conn
          |> put_status(:bad_request)
          |> json(%{success: false, error: "No images found in campaign"})
        else
          # Test image selection
          case AiService.select_image_pairs_for_scenes(assets, brief, scene_count, %{}) do
            {:ok, scenes} ->
              # Enrich with asset details
              enriched_scenes = enrich_scenes_with_assets(scenes, assets)

              json(conn, %{
                success: true,
                campaign_id: campaign_id,
                campaign_name: campaign.name,
                total_assets: length(assets),
                scene_count: length(scenes),
                scenes: enriched_scenes
              })

            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{success: false, error: reason})
          end
        end
    end
  end

  @doc """
  POST /api/v3/testing/music/single-scene
  Tests music generation for a single scene.

  Body:
    {
      "scene": {
        "title": "The Hook",
        "description": "...",
        "duration": 4,
        "music_description": "...",
        "music_style": "...",
        "music_energy": "..."
      }
    }
  """
  def test_single_scene_music(conn, %{"scene" => scene_params}) do
    Logger.info("[TestingController] Testing single scene music generation")

    duration = Map.get(scene_params, "duration", 8.0) |> parse_duration()
    options = %{duration: duration}

    case MusicgenService.generate_scene_audio(scene_params, options) do
      {:ok, result} ->
        # Encode audio as Base64 for JSON response
        audio_base64 = Base.encode64(result.audio_blob)
        
        json(conn, %{
          success: true,
          scene_title: scene_params["title"],
          duration: duration,
          audio_size_bytes: byte_size(result.audio_blob),
          total_duration: Map.get(result, :total_duration, duration),
          audio_base64: audio_base64,
          prompt_used: build_music_prompt_preview(scene_params)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  defp parse_duration(nil), do: 8.0
  defp parse_duration(duration) when is_float(duration), do: duration
  defp parse_duration(duration) when is_integer(duration), do: duration * 1.0
  defp parse_duration(duration) when is_binary(duration) do
    case Float.parse(duration) do
      {float_val, _} -> float_val
      :error -> 8.0
    end
  end
  defp parse_duration(_), do: 8.0

  @doc """
  POST /api/v3/testing/music/multi-scene
  Tests music generation for multiple scenes with continuation.

  Body:
    {
      "scenes": [...],
      "default_duration": 4.0,
      "fade_duration": 1.5
    }
  """
  def test_multi_scene_music(conn, %{"scenes" => scenes} = params) do
    Logger.info("[TestingController] Testing multi-scene music generation for #{length(scenes)} scenes")

    options = %{
      default_duration: Map.get(params, "default_duration", 4.0),
      fade_duration: Map.get(params, "fade_duration", 1.5)
    }

    case MusicgenService.generate_music_for_scenes(scenes, options) do
      {:ok, final_audio_blob} ->
        # Calculate expected vs actual duration
        expected_duration = Enum.sum(Enum.map(scenes, &(Map.get(&1, "duration", 4.0))))

        json(conn, %{
          success: true,
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          expected_duration_seconds: expected_duration,
          scenes_processed: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  POST /api/v3/testing/music/from-templates
  Generates music using scene templates.

  Body:
    {
      "scene_types": ["hook", "bedroom", "vanity", "tub", "living_room", "dining", "outro"],
      "default_duration": 4.0
    }
  """
  def test_music_from_templates(conn, params) do
    scene_types = Map.get(params, "scene_types", [:hook, :bedroom, :vanity, :tub, :living_room, :dining, :outro])
    default_duration = Map.get(params, "default_duration", 4.0)

    # Convert string types to atoms if needed
    scene_types =
      Enum.map(scene_types, fn
        type when is_binary(type) -> String.to_existing_atom(type)
        type when is_atom(type) -> type
      end)

    # Get templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Convert templates to scene maps
    scenes =
      Enum.map(templates, fn template ->
        %{
          "title" => template.title,
          "description" => template.video_prompt |> String.trim(),
          "duration" => default_duration,
          "music_description" => template.music_description,
          "music_style" => template.music_style,
          "music_energy" => template.music_energy
        }
      end)

    options = %{
      default_duration: default_duration,
      fade_duration: 1.5
    }

    case MusicgenService.generate_music_for_scenes(scenes, options) do
      {:ok, final_audio_blob} ->
        # Encode audio as Base64 for JSON response
        audio_base64 = Base.encode64(final_audio_blob)
        
        json(conn, %{
          success: true,
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          total_duration_seconds: length(scenes) * default_duration,
          audio_base64: audio_base64,
          scenes: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  POST /api/v3/testing/music/elevenlabs
  Generates music using ElevenLabs API with scene templates.

  Body:
    {
      "scene_types": ["hook", "bedroom", "vanity", "tub", "living_room", "dining", "outro"],
      "default_duration": 4.0
    }
  """
  def test_music_elevenlabs(conn, params) do
    alias Backend.Services.ElevenlabsMusicService

    scene_types = Map.get(params, "scene_types", [:hook, :bedroom, :vanity, :tub, :living_room, :dining, :outro])
    default_duration = Map.get(params, "default_duration", 4.0)

    # Convert string types to atoms if needed
    scene_types =
      Enum.map(scene_types, fn
        type when is_binary(type) -> String.to_existing_atom(type)
        type when is_atom(type) -> type
      end)

    # Get templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Convert templates to scene maps
    scenes =
      Enum.map(templates, fn template ->
        %{
          "title" => template.title,
          "description" => template.video_prompt |> String.trim(),
          "duration" => default_duration,
          "music_description" => template.music_description,
          "music_style" => template.music_style,
          "music_energy" => template.music_energy
        }
      end)

    options = %{
      default_duration: default_duration,
      fade_duration: 1.5
    }

    case ElevenlabsMusicService.generate_music_for_scenes(scenes, options) do
      {:ok, final_audio_blob} ->
        # Encode audio as Base64 for JSON response
        audio_base64 = Base.encode64(final_audio_blob)
        
        json(conn, %{
          success: true,
          provider: "elevenlabs",
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          total_duration_seconds: length(scenes) * default_duration,
          audio_base64: audio_base64,
          scenes: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason, provider: "elevenlabs"})
    end
  end

  @doc """
  POST /api/v3/testing/music/elevenlabs-28s
  Generates a single 28-second cohesive track using ElevenLabs composition plan with seamless segues.
  """
  def test_music_elevenlabs_28s(conn, params) do
    alias Backend.Services.ElevenlabsMusicService

    scene_types = Map.get(params, "scene_types", [:hook, :bedroom, :vanity, :tub, :living_room, :dining, :outro])
    default_duration = Map.get(params, "default_duration", 4.0)

    # Convert string types to atoms if needed
    scene_types =
      Enum.map(scene_types, fn
        type when is_binary(type) -> String.to_existing_atom(type)
        type when is_atom(type) -> type
      end)

    # Get templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Convert templates to scene maps
    scenes =
      Enum.map(templates, fn template ->
        %{
          "title" => template.title,
          "description" => template.video_prompt |> String.trim(),
          "duration" => default_duration,
          "music_description" => template.music_description,
          "music_style" => template.music_style,
          "music_energy" => template.music_energy
        }
      end)

    options = %{
      default_duration: default_duration,
      fade_duration: 1.5
    }

    case ElevenlabsMusicService.generate_music_for_scenes(scenes, options) do
      {:ok, final_audio_blob} ->
        # Encode audio as Base64 for JSON response
        audio_base64 = Base.encode64(final_audio_blob)
        
        json(conn, %{
          success: true,
          provider: "elevenlabs",
          method: "28s-composition-plan",
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          total_duration_seconds: 28.0,
          audio_base64: audio_base64,
          description: "Single cohesive 28-second track with seamless segues between sections (12s + 12s + 4s)",
          scenes: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason, provider: "elevenlabs", method: "28s-composition-plan"})
    end
  end

  @doc """
  POST /api/v3/testing/music/elevenlabs-3chunk
  Generates music using ElevenLabs API with 3-chunk approach (12s + 12s + 4s with fade).
  """
  def test_music_elevenlabs_3chunk(conn, params) do
    alias Backend.Services.ElevenlabsMusicService

    scene_types = Map.get(params, "scene_types", [:hook, :bedroom, :vanity, :tub, :living_room, :dining, :outro])
    default_duration = Map.get(params, "default_duration", 4.0)

    # Convert string types to atoms if needed
    scene_types =
      Enum.map(scene_types, fn
        type when is_binary(type) -> String.to_existing_atom(type)
        type when is_atom(type) -> type
      end)

    # Get templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Convert templates to scene maps
    scenes =
      Enum.map(templates, fn template ->
        %{
          "title" => template.title,
          "description" => template.video_prompt |> String.trim(),
          "duration" => default_duration,
          "music_description" => template.music_description,
          "music_style" => template.music_style,
          "music_energy" => template.music_energy
        }
      end)

    options = %{
      default_duration: default_duration,
      fade_duration: 1.5
    }

    case ElevenlabsMusicService.generate_music_for_scenes(scenes, options) do
      {:ok, final_audio_blob} ->
        # Encode audio as Base64 for JSON response
        audio_base64 = Base.encode64(final_audio_blob)
        
        json(conn, %{
          success: true,
          provider: "elevenlabs",
          method: "3chunk",
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          total_duration_seconds: 28.0,
          audio_base64: audio_base64,
          chunks: %{
            chunk1: "12s (scenes 1-3)",
            chunk2: "12s (scenes 4-6)",
            chunk3: "4s (scene 7)"
          },
          scenes: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason, provider: "elevenlabs", method: "3chunk"})
    end
  end

  @doc """
  POST /api/v3/testing/music/rapid
  Rapid music generation test using only scenes 1-3 (hook, bedroom, vanity).
  """
  def test_music_rapid(conn, params) do
    # Only use first 3 scenes for rapid testing
    scene_types = [:hook, :bedroom, :vanity]
    default_duration = Map.get(params, "default_duration", 4.0)

    # Get templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Convert templates to scene maps
    scenes =
      Enum.map(templates, fn template ->
        %{
          "title" => template.title,
          "description" => template.video_prompt |> String.trim(),
          "duration" => default_duration,
          "music_description" => template.music_description,
          "music_style" => template.music_style,
          "music_energy" => template.music_energy
        }
      end)

    options = %{
      default_duration: default_duration,
      fade_duration: 1.5
    }

    Logger.info("[TestingController] Rapid music test: generating for #{length(scenes)} scenes")

    case MusicgenService.generate_music_for_scenes(scenes, options) do
      {:ok, final_audio_blob} ->
        # Encode audio as Base64 for JSON response
        audio_base64 = Base.encode64(final_audio_blob)
        
        json(conn, %{
          success: true,
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          total_duration_seconds: length(scenes) * default_duration,
          audio_base64: audio_base64,
          scenes: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  POST /api/v3/testing/music/chunk
  Generates a single 28-second audio clip combining all scene prompts in one go (no continuation).
  """
  def test_music_chunk(conn, params) do
    default_duration = Map.get(params, "default_duration", 28.0)
    scene_types = [:hook, :bedroom, :vanity, :tub, :living_room, :dining, :outro]

    # Get all templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Combine all scene prompts into one comprehensive prompt
    # Simple, clean prompt - back to basics when we first added piano
    combined_prompt = 
      templates
      |> Enum.map(fn template ->
        "#{template.music_description} (#{template.music_style}, #{template.music_energy})"
      end)
      |> Enum.join(", ")
      |> then(fn desc ->
        "Upbeat piano music, luxury vacation getaway. #{desc}. Instrumental, cinematic, piano-focused, smooth and flowing. Gentle fade out at the end."
      end)

    # Create a single scene with combined prompt
    single_scene = %{
      "title" => "Complete 28-Second Track",
      "description" => "Combined luxury vacation getaway music",
      "duration" => default_duration,
      "music_description" => combined_prompt,
      "music_style" => "cinematic, piano-focused, smooth",
      "music_energy" => "medium-high"
    }

    Logger.info("[TestingController] Chunk music generation: single #{default_duration}s clip with combined prompts")

    # Generate single audio clip (no continuation)
    # Pass the combined prompt directly in options to avoid double-wrapping
    case MusicgenService.generate_scene_audio(single_scene, %{duration: default_duration, prompt: combined_prompt}) do
      {:ok, audio_data} ->
        audio_blob = audio_data.audio_blob
        audio_base64 = Base.encode64(audio_blob)
        
        json(conn, %{
          success: true,
          scene_count: 1,
          audio_size_bytes: byte_size(audio_blob),
          total_duration_seconds: Map.get(audio_data, :total_duration, default_duration),
          audio_base64: audio_base64,
          method: "chunk",
          combined_prompt: combined_prompt
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  POST /api/v3/testing/music/3chunk
  Generates music in 3 chunks using continuation:
  - Chunk 1: 12 seconds (no continuation)
  - Chunk 2: 24 seconds total (uses chunk 1 output, continuation)
  - Chunk 3: 28 seconds total (uses chunk 2 output, continuation)
  """
  def test_music_3chunk(conn, _params) do
    scene_types = [:hook, :bedroom, :vanity, :tub, :living_room, :dining, :outro]

    # Get all templates
    templates =
      scene_types
      |> Enum.map(&SceneTemplates.get_template/1)
      |> Enum.reject(&is_nil/1)

    # Build prompts for each chunk
    # Chunk 1: scenes 1-3 (hook, bedroom, vanity) = 12 seconds
    chunk1_templates = Enum.take(templates, 3)
    chunk1_prompt = build_chunk_prompt(chunk1_templates, false)

    # Chunk 2: scenes 4-6 (tub, living_room, dining) = 12 more seconds (24 total)
    chunk2_templates = Enum.slice(templates, 3, 3)
    chunk2_prompt = build_chunk_prompt(chunk2_templates, false)

    # Chunk 3: scene 7 (outro) = 4 more seconds (28 total)
    chunk3_templates = Enum.slice(templates, 6, 1)
    chunk3_prompt = build_chunk_prompt(chunk3_templates, true)  # Last scene, add fade

    Logger.info("[TestingController] 3-Chunk music generation: 12s + 12s + 4s = 28s total")

    # Chunk 1: 12 seconds, no continuation
    chunk1_scene = %{
      "title" => "Chunk 1 (0-12s)",
      "description" => "First 12 seconds",
      "duration" => 12.0,
      "music_description" => chunk1_prompt,
      "music_style" => "cinematic, piano-focused, smooth",
      "music_energy" => "medium-high"
    }

    case MusicgenService.generate_scene_audio(chunk1_scene, %{duration: 12.0, prompt: chunk1_prompt}) do
      {:ok, chunk1_audio} ->
        Logger.info("[TestingController] Chunk 1 complete: #{Map.get(chunk1_audio, :total_duration, 12.0)}s")

        # Chunk 2: 24 seconds total, continuation from chunk 1
        chunk2_scene = %{
          "title" => "Chunk 2 (12-24s)",
          "description" => "Next 12 seconds",
          "duration" => 24.0,  # Total duration including chunk 1
          "music_description" => chunk2_prompt,
          "music_style" => "cinematic, piano-focused, smooth",
          "music_energy" => "medium-high"
        }

        case MusicgenService.generate_with_continuation(chunk2_scene, chunk1_audio, %{duration: 24.0, prompt: chunk2_prompt}) do
          {:ok, chunk2_audio} ->
            Logger.info("[TestingController] Chunk 2 complete: #{Map.get(chunk2_audio, :total_duration, 24.0)}s")

            # Chunk 3: 28 seconds total, continuation from chunk 2
            chunk3_scene = %{
              "title" => "Chunk 3 (24-28s)",
              "description" => "Final 4 seconds",
              "duration" => 28.0,  # Total duration including chunks 1 and 2
              "music_description" => chunk3_prompt,
              "music_style" => "cinematic, piano-focused, smooth",
              "music_energy" => "medium-high"
            }

            case MusicgenService.generate_with_continuation(chunk3_scene, chunk2_audio, %{duration: 28.0, prompt: chunk3_prompt, is_last_scene: true}) do
              {:ok, chunk3_audio} ->
                Logger.info("[TestingController] Chunk 3 complete: #{Map.get(chunk3_audio, :total_duration, 28.0)}s")
                audio_blob = chunk3_audio.audio_blob
                audio_base64 = Base.encode64(audio_blob)

                json(conn, %{
                  success: true,
                  method: "3chunk",
                  chunk_count: 3,
                  audio_size_bytes: byte_size(audio_blob),
                  total_duration_seconds: Map.get(chunk3_audio, :total_duration, 28.0),
                  audio_base64: audio_base64,
                  chunks: %{
                    chunk1: %{duration: 12.0, prompt: chunk1_prompt},
                    chunk2: %{duration: 24.0, prompt: chunk2_prompt},
                    chunk3: %{duration: 28.0, prompt: chunk3_prompt}
                  }
                })

              {:error, reason} ->
                Logger.error("[TestingController] Chunk 3 failed: #{inspect(reason)}")
                conn
                |> put_status(:internal_server_error)
                |> json(%{success: false, error: "Chunk 3 failed: #{reason}"})
            end

          {:error, reason} ->
            Logger.error("[TestingController] Chunk 2 failed: #{inspect(reason)}")
            conn
            |> put_status(:internal_server_error)
            |> json(%{success: false, error: "Chunk 2 failed: #{reason}"})
        end

      {:error, reason} ->
        Logger.error("[TestingController] Chunk 1 failed: #{inspect(reason)}")
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: "Chunk 1 failed: #{reason}"})
    end
  end

  defp build_chunk_prompt(templates, is_last_scene) do
    combined_desc =
      templates
      |> Enum.map(fn template ->
        "#{template.music_description} (#{template.music_style}, #{template.music_energy})"
      end)
      |> Enum.join(", ")

    fade_instruction = if is_last_scene do
      " Gentle fade out at the end."
    else
      " Smooth continuation."
    end

    "Upbeat piano music, luxury vacation getaway. #{combined_desc}. Instrumental, cinematic, piano-focused, smooth and flowing#{fade_instruction}"
  end

  @doc """
  GET /api/v3/testing/campaigns
  Lists available campaigns for testing.
  """
  def list_campaigns(conn, _params) do
    campaigns =
      Campaign
      |> limit(50)
      |> order_by([c], desc: c.inserted_at)
      |> Repo.all()
      |> Enum.map(fn campaign ->
        asset_count =
          Asset
          |> where([a], a.campaign_id == ^campaign.id and a.type == :image)
          |> Repo.aggregate(:count, :id)

        %{
          id: campaign.id,
          name: campaign.name,
          brief: campaign.brief,
          image_count: asset_count,
          inserted_at: campaign.inserted_at
        }
      end)

    json(conn, %{
      success: true,
      count: length(campaigns),
      campaigns: campaigns
    })
  end

  @doc """
  GET /api/v3/testing/jobs
  Lists completed jobs with videos and/or audio.
  
  Query params:
    - status: Filter by status (completed, processing, etc.)
    - has_video: Filter jobs that have video (true/false)
    - has_audio: Filter jobs that have audio (true/false)
  """
  def list_jobs(conn, params) do
    query = Job

    # Filter by status if provided
    query =
      if status = params["status"] do
        status_atom = String.to_existing_atom(status)
        where(query, [j], j.status == ^status_atom)
      else
        query
      end

    # Filter by has_video
    query =
      if params["has_video"] == "true" do
        where(query, [j], not is_nil(j.result))
      else
        query
      end

    # Filter by has_audio
    query =
      if params["has_audio"] == "true" do
        where(query, [j], not is_nil(j.audio_blob))
      else
        query
      end

    jobs =
      query
      |> order_by([j], desc: j.updated_at)
      |> limit(50)
      |> Repo.all()
      |> Enum.map(fn job ->
        # Get scene count from storyboard
        scene_count =
          case job.storyboard do
            %{"scenes" => scenes} when is_list(scenes) -> length(scenes)
            scenes when is_list(scenes) -> length(scenes)
            _ -> 0
          end

        # Get video and audio sizes
        video_size_mb =
          if job.result do
            Float.round(byte_size(job.result) / (1024 * 1024), 2)
          else
            nil
          end

        audio_size_mb =
          if job.audio_blob do
            Float.round(byte_size(job.audio_blob) / (1024 * 1024), 2)
          else
            nil
          end

        %{
          id: job.id,
          type: job.type,
          status: job.status,
          scene_count: scene_count,
          has_video: not is_nil(job.result),
          has_audio: not is_nil(job.audio_blob),
          video_size_mb: video_size_mb,
          audio_size_mb: audio_size_mb,
          video_url: if(job.result, do: "/api/v3/videos/#{job.id}/combined", else: nil),
          audio_url: if(job.audio_blob, do: "/api/v3/audio/#{job.id}/download", else: nil),
          thumbnail_url: if(job.result, do: "/api/v3/videos/#{job.id}/thumbnail", else: nil),
          inserted_at: job.inserted_at,
          updated_at: job.updated_at
        }
      end)

    json(conn, %{
      success: true,
      count: length(jobs),
      jobs: jobs
    })
  end

  @doc """
  GET /api/v3/testing/campaigns/:id/assets
  Gets assets for a campaign with metadata.
  """
  def campaign_assets(conn, %{"id" => campaign_id}) do
    case Repo.get(Campaign, campaign_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "Campaign not found"})

      campaign ->
        assets =
          Asset
          |> where([a], a.campaign_id == ^campaign_id and a.type == :image)
          |> order_by([a], asc: a.inserted_at)
          |> Repo.all()
          |> Enum.map(fn asset ->
            %{
              id: asset.id,
              type: asset.type,
              source_url: asset.source_url,
              metadata: asset.metadata || %{},
              has_blob: !is_nil(asset.blob_data),
              blob_size: if(asset.blob_data, do: byte_size(asset.blob_data), else: 0),
              asset_url: "/api/v3/assets/#{asset.id}/data"
            }
          end)

        json(conn, %{
          success: true,
          campaign_id: campaign.id,
          campaign_name: campaign.name,
          asset_count: length(assets),
          assets: assets
        })
    end
  end

  @doc """
  POST /api/v3/testing/prompt-preview
  Generates prompt previews without actually calling the API.

  Body:
    {
      "scene_type": "hook",
      "for": "video" | "music"
    }
  """
  def prompt_preview(conn, %{"scene_type" => scene_type_str, "for" => prompt_type}) do
    scene_type =
      case scene_type_str do
        s when is_binary(s) -> String.to_existing_atom(s)
        a when is_atom(a) -> a
      end

    case SceneTemplates.get_template(scene_type) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "Scene type not found"})

      template ->
        result =
          case prompt_type do
            "video" ->
              %{
                prompt_type: "video",
                prompt: template.video_prompt |> String.trim(),
                motion_goal: template.motion_goal,
                camera_movement: template.camera_movement
              }

            "music" ->
              %{
                prompt_type: "music",
                description: template.music_description,
                style: template.music_style,
                energy: template.music_energy,
                generated_prompt:
                  SceneTemplates.generate_music_prompt(template, base_style: "luxury real estate")
              }

            _ ->
              %{error: "Invalid prompt type. Use 'video' or 'music'"}
          end

        json(conn, Map.merge(%{success: true, scene_type: scene_type, template: template.title}, result))
    end
  end

  @doc """
  GET /api/v3/testing/jobs/:id/preview
  Gets detailed preview of a job's scenes and selections.
  """
  def job_preview(conn, %{"id" => job_id}) do
    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "Job not found"})

      job ->
        scenes = get_in(job.storyboard, ["scenes"]) || []

        # Load assets
        asset_ids = scenes |> Enum.flat_map(&(Map.get(&1, "asset_ids", []))) |> Enum.uniq()

        assets =
          if asset_ids != [] do
            Asset
            |> where([a], a.id in ^asset_ids)
            |> Repo.all()
            |> Enum.map(fn asset ->
              {asset.id,
               %{
                 id: asset.id,
                 metadata: asset.metadata || %{},
                 asset_url: "/api/v3/assets/#{asset.id}/data"
               }}
            end)
            |> Map.new()
          else
            %{}
          end

        enriched_scenes =
          Enum.map(scenes, fn scene ->
            scene_asset_ids = Map.get(scene, "asset_ids", [])

            scene_assets =
              scene_asset_ids
              |> Enum.map(&Map.get(assets, &1))
              |> Enum.reject(&is_nil/1)

            Map.merge(scene, %{
              "assets" => scene_assets,
              "asset_count" => length(scene_assets)
            })
          end)

        json(conn, %{
          success: true,
          job_id: job.id,
          job_type: job.type,
          status: job.status,
          scene_count: length(scenes),
          total_assets: map_size(assets),
          scenes: enriched_scenes,
          parameters: job.parameters || %{}
        })
    end
  end

  @doc """
  POST /api/v3/testing/overlay/text
  Tests text overlay on a video.

  Body:
    {
      "job_id": 123,  // Use video from completed job
      "text": "Luxury Mountain Retreat",
      "options": {
        "font": "Arial",
        "font_size": 48,
        "color": "white",
        "position": "bottom_center",
        "fade_in": 0.5,
        "fade_out": 0.5
      }
    }
  """
  def test_text_overlay(conn, %{"job_id" => job_id, "text" => text} = params) do
    raw_options = Map.get(params, "options", %{})
    overlay_keys = [:font, :font_size, :color, :position, :fade_in, :fade_out, :start_time, :duration]
    options = atomize_keys(raw_options, overlay_keys)

    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "Job not found"})

      %Job{result: nil} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Job has no video result yet"})

      %Job{result: video_blob} ->
        case OverlayService.add_text_overlay(video_blob, text, options) do
          {:ok, video_with_overlay} ->
            json(conn, %{
              success: true,
              job_id: job_id,
              text: text,
              options: options,
              original_size: byte_size(video_blob),
              output_size: byte_size(video_with_overlay)
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{success: false, error: reason})
        end
    end
  end

  @doc """
  POST /api/v3/testing/overlay/preview
  Previews text overlay settings without processing video.
  """
  def preview_text_overlay(conn, %{"text" => text} = params) do
    raw_options = Map.get(params, "options", %{})
    overlay_keys = [:font, :font_size, :color, :position, :fade_in, :fade_out, :start_time, :duration]
    options = atomize_keys(raw_options, overlay_keys)
    preview = OverlayService.preview_text_overlay(text, options)

    json(conn, %{
      success: true,
      preview: preview
    })
  end

  @doc """
  POST /api/v3/testing/voiceover/generate
  Tests voiceover generation from script.

  Body:
    {
      "script": "Welcome to this exceptional property...",
      "options": {
        "provider": "elevenlabs",
        "voice": "professional",
        "speed": 1.0
      }
    }
  """
  def test_voiceover_generation(conn, %{"script" => script} = params) do
    raw_options = Map.get(params, "options", %{})
    voiceover_keys = [:provider, :voice, :stability, :similarity_boost, :speed, :model]
    options = atomize_keys(raw_options, voiceover_keys)

    case TtsService.generate_voiceover(script, options) do
      {:ok, audio_blob} ->
        json(conn, %{
          success: true,
          script: script,
          audio_size_bytes: byte_size(audio_blob),
          estimated_duration: estimate_audio_duration(script),
          options: options
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  POST /api/v3/testing/voiceover/script
  Generates voiceover script from property details and scenes.

  Body:
    {
      "property_details": {
        "name": "Mountain Vista Estate",
        "type": "luxury mountain retreat",
        "features": ["infinity pool", "mountain views", "spa"],
        "location": "Aspen, Colorado"
      },
      "scenes": [...],
      "options": {
        "tone": "professional and engaging",
        "style": "luxury real estate"
      }
    }
  """
  def generate_voiceover_script(conn, params) do
    raw_property_details = Map.get(params, "property_details", %{})
    property_keys = [:name, :type, :features, :location]
    property_details = atomize_keys(raw_property_details, property_keys)

    scenes = Map.get(params, "scenes", [])

    raw_options = Map.get(params, "options", %{})
    script_keys = [:tone, :style, :length]
    options = atomize_keys(raw_options, script_keys)

    case TtsService.generate_script(property_details, scenes, options) do
      {:ok, script_data} ->
        json(conn, %{
          success: true,
          property_details: property_details,
          scene_count: length(scenes),
          script: script_data
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  POST /api/v3/testing/avatar/preview
  Stub for avatar overlay testing (future feature).

  Body:
    {
      "avatar_type": "talking_head",
      "position": "bottom_right",
      "size": "small"
    }
  """
  def test_avatar_overlay(conn, params) do
    avatar_type = Map.get(params, "avatar_type", "talking_head")
    position = Map.get(params, "position", "bottom_right")
    size = Map.get(params, "size", "small")

    json(conn, %{
      success: true,
      status: "stub",
      message: "Avatar overlay feature not yet implemented",
      requested_config: %{
        avatar_type: avatar_type,
        position: position,
        size: size
      },
      note: "This endpoint is a placeholder for future avatar overlay functionality"
    })
  end

  @doc """
  GET /api/v3/testing/pipeline/config
  Gets current pipeline configuration.
  """
  def get_pipeline_config(conn, _params) do
    config = PipelineConfig.get_config()

    json(conn, %{
      success: true,
      config: config,
      enabled_steps:
        config
        |> Enum.filter(fn {_key, val} -> is_map(val) and Map.get(val, :enabled, false) end)
        |> Enum.map(fn {key, _val} -> key end)
    })
  end

  @doc """
  POST /api/v3/testing/pipeline/config
  Updates pipeline configuration.

  Body:
    {
      "step": "text_overlays",
      "updates": {
        "enabled": true,
        "default_font_size": 60
      }
    }

    OR

    {
      "config": {
        "text_overlays": { "enabled": true },
        "voiceover": { "enabled": false }
      }
    }
  """
  def update_pipeline_config(conn, %{"step" => step_str, "updates" => updates}) do
    step = String.to_existing_atom(step_str)

    case PipelineConfig.update_step(step, atomize_keys(updates)) do
      {:ok, updated_step} ->
        json(conn, %{
          success: true,
          step: step,
          updated_config: updated_step
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: reason})
    end
  end

  def update_pipeline_config(conn, %{"config" => config_updates}) do
    case PipelineConfig.update_config(atomize_keys(config_updates)) do
      {:ok, new_config} ->
        json(conn, %{
          success: true,
          config: new_config
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: reason})
    end
  end

  @doc """
  GET /api/v3/testing/ui
  Serves the testing UI HTML page.
  """
  def testing_ui(conn, _params) do
    html_content = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>AI Video Pipeline Testing</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif; background: #f5f5f5; padding: 20px; }
        .container { max-width: 1400px; margin: 0 auto; }
        h1 { color: #333; margin-bottom: 30px; font-size: 28px; }
        .section { background: white; padding: 25px; margin-bottom: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h2 { color: #444; font-size: 20px; margin-bottom: 15px; border-bottom: 2px solid #007bff; padding-bottom: 10px; }
        .form-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 5px; font-weight: 600; color: #555; }
        input, textarea, select { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; }
        textarea { min-height: 100px; font-family: monospace; }
        button { background: #007bff; color: white; padding: 12px 24px; border: none; border-radius: 4px; cursor: pointer; font-size: 14px; font-weight: 600; }
        button:hover { background: #0056b3; }
        button:disabled { background: #ccc; cursor: not-allowed; }
        .result { margin-top: 15px; padding: 15px; background: #f8f9fa; border-left: 4px solid #007bff; border-radius: 4px; }
        .error { border-left-color: #dc3545; background: #f8d7da; }
        .success { border-left-color: #28a745; background: #d4edda; }
        pre { background: #282c34; color: #abb2bf; padding: 15px; border-radius: 4px; overflow-x: auto; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr)); gap: 20px; }
        .loading { display: inline-block; width: 14px; height: 14px; border: 2px solid #fff; border-radius: 50%; border-top-color: transparent; animation: spin 1s linear infinite; margin-left: 8px; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .config-item { padding: 10px; margin: 5px 0; background: #f8f9fa; border-radius: 4px; display: flex; justify-content: space-between; align-items: center; }
        .toggle { position: relative; display: inline-block; width: 50px; height: 24px; }
        .toggle input { opacity: 0; width: 0; height: 0; }
        .slider { position: absolute; cursor: pointer; top: 0; left: 0; right: 0; bottom: 0; background-color: #ccc; transition: .4s; border-radius: 24px; }
        .slider:before { position: absolute; content: ""; height: 16px; width: 16px; left: 4px; bottom: 4px; background-color: white; transition: .4s; border-radius: 50%; }
        input:checked + .slider { background-color: #007bff; }
        input:checked + .slider:before { transform: translateX(26px); }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>🎬 AI Video Pipeline Testing Interface</h1>

        <div class="section">
          <h2>Pipeline Configuration</h2>
          <button onclick="loadPipelineConfig()">Load Config</button>
          <div id="pipelineConfig"></div>
        </div>

        <div class="grid">
          <div class="section">
            <h2>1. Scene Templates</h2>
            <button onclick="loadSceneTemplates()">Load Templates</button>
            <div id="templateResult"></div>
          </div>

          <div class="section">
            <h2>2. Image Selection</h2>
            <div class="form-group">
              <label>Campaign ID:</label>
              <input type="text" id="campaignId" placeholder="313e2460-2520-401b-86f4-385ebe41d4b8">
            </div>
            <div class="form-group">
              <label>Scene Count:</label>
              <input type="number" id="sceneCount" value="7" min="2" max="10">
            </div>
            <button onclick="testImageSelection()">Test Selection</button>
            <div id="imageResult"></div>
          </div>

          <div class="section">
            <h2>3. Music Generation</h2>
            <div class="form-group">
              <label>Scene Types (comma-separated):</label>
              <input type="text" id="sceneTypes" value="hook,bedroom,vanity,tub,living_room,dining,outro">
            </div>
            <button onclick="testMusicGeneration()">Generate Music (MusicGen)</button>
            <button onclick="testMusicElevenlabs()" style="margin-left: 10px; background: #28a745; color: #fff;">Generate Music (ElevenLabs)</button>
            <button onclick="testMusicElevenlabs28s()" style="margin-left: 10px; background: #dc3545; color: #fff; font-weight: bold;">🎵 ElevenLabs 28s (Seamless Segues)</button>
            <button onclick="testMusicElevenlabs3Chunk()" style="margin-left: 10px; background: #20c997; color: #fff; font-weight: bold;">🎵 ElevenLabs 3-Chunk (12s+12s+4s)</button>
            <button onclick="testMusicRapid()" style="margin-left: 10px; background: #ffc107; color: #000;">Generate Music Rapid (Scenes 1-3)</button>
            <button onclick="testMusicChunk()" style="margin-left: 10px; background: #17a2b8; color: #fff;">Generate Music - Chunk (28s single)</button>
            <button onclick="testMusic3Chunk()" style="margin-left: 10px; background: #6f42c1; color: #fff;">Generate Music - 3 Chunk (12s+12s+4s)</button>
            <div id="musicResult"></div>
          </div>

          <div class="section">
            <h2>4. Text Overlay</h2>
            <div class="form-group">
              <label>Job ID:</label>
              <input type="number" id="overlayJobId" placeholder="123">
            </div>
            <div class="form-group">
              <label>Text:</label>
              <input type="text" id="overlayText" value="Luxury Mountain Retreat">
            </div>
            <button onclick="previewTextOverlay()">Preview Settings</button>
            <div id="overlayResult"></div>
          </div>

          <div class="section">
            <h2>5. Voiceover Script</h2>
            <div class="form-group">
              <label>Property Name:</label>
              <input type="text" id="propertyName" value="Mountain Vista Estate">
            </div>
            <button onclick="generateScript()">Generate Script</button>
            <div id="voiceoverResult"></div>
          </div>

          <div class="section">
            <h2>6. Campaigns List</h2>
            <button onclick="loadCampaigns()">Load Campaigns</button>
            <div id="campaignsResult"></div>
          </div>

          <div class="section">
            <h2>7. Completed Jobs (Videos & Audio)</h2>
            <div class="form-group">
              <label>Status:</label>
              <select id="jobStatusFilter">
                <option value="">All</option>
                <option value="completed" selected>Completed</option>
                <option value="processing">Processing</option>
                <option value="failed">Failed</option>
              </select>
            </div>
            <div class="form-group">
              <label>
                <input type="checkbox" id="hasVideoFilter" checked> Has Video
              </label>
            </div>
            <div class="form-group">
              <label>
                <input type="checkbox" id="hasAudioFilter"> Has Audio
              </label>
            </div>
            <button onclick="loadJobs()">Load Jobs</button>
            <div id="jobsResult"></div>
          </div>
        </div>
      </div>

      <script>
        const API_BASE = '/api/v3/testing';
        const API_KEY = localStorage.getItem('api_key') || prompt('Enter API Key:');
        if (API_KEY) localStorage.setItem('api_key', API_KEY);

        async function apiCall(endpoint, method = 'GET', body = null) {
          const options = {
            method,
            headers: { 'X-API-Key': API_KEY, 'Content-Type': 'application/json' }
          };
          if (body) options.body = JSON.stringify(body);

          const res = await fetch(API_BASE + endpoint, options);
          return res.json();
        }

        async function loadSceneTemplates() {
          const result = document.getElementById('templateResult');
          result.innerHTML = '<div class="result">Loading...</div>';
          try {
            const data = await apiCall('/scene-templates');
            result.innerHTML = `<div class="result success"><pre>${JSON.stringify(data, null, 2)}</pre></div>`;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testImageSelection() {
          const campaignId = document.getElementById('campaignId').value;
          const sceneCount = document.getElementById('sceneCount').value;
          if (!campaignId) return alert('Enter Campaign ID');

          const result = document.getElementById('imageResult');
          result.innerHTML = '<div class="result">Processing...</div>';
          try {
            const data = await apiCall('/image-selection', 'POST', {
              campaign_id: campaignId,
              scene_count: parseInt(sceneCount),
              brief: 'Luxury property showcase'
            });
            result.innerHTML = `<div class="result success"><pre>${JSON.stringify(data, null, 2)}</pre></div>`;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusicGeneration() {
          const sceneTypes = document.getElementById('sceneTypes').value.split(',').map(s => s.trim());
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating music with MusicGen (this may take a minute)...</div>';
          try {
            const data = await apiCall('/music/from-templates', 'POST', {
              scene_types: sceneTypes,
              default_duration: 4.0
            });
            
            let html = '<div class="result success">';
            html += `<h3>🎵 Music Generated Successfully! (MusicGen)</h3>`;
            html += `<p><strong>Provider:</strong> MusicGen (Replicate)</p>`;
            html += `<p><strong>Scenes:</strong> ${data.scene_count}</p>`;
            html += `<p><strong>Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="generated_music_musicgen.mp3" style="display: inline-block; background: #28a745; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusicElevenlabs() {
          const sceneTypes = document.getElementById('sceneTypes').value.split(',').map(s => s.trim());
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating music with ElevenLabs (this may take a minute)...</div>';
          try {
            const data = await apiCall('/music/elevenlabs', 'POST', {
              scene_types: sceneTypes,
              default_duration: 4.0
            });
            
            let html = '<div class="result success">';
            html += `<h3>🎵 Music Generated Successfully! (ElevenLabs)</h3>`;
            html += `<p><strong>Provider:</strong> ElevenLabs</p>`;
            html += `<p><strong>Scenes:</strong> ${data.scene_count}</p>`;
            html += `<p><strong>Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="generated_music_elevenlabs.mp3" style="display: inline-block; background: #28a745; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusicElevenlabs28s() {
          const sceneTypes = document.getElementById('sceneTypes').value.split(',').map(s => s.trim());
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating 28-second cohesive track with ElevenLabs composition plan (seamless segues, ~60-90 seconds)...</div>';
          try {
            const data = await apiCall('/music/elevenlabs-28s', 'POST', {
              scene_types: sceneTypes,
              default_duration: 4.0
            });
            
            let html = '<div class="result success">';
            html += `<h3>🎵 ElevenLabs 28-Second Track Generated!</h3>`;
            html += `<p><strong>Provider:</strong> ElevenLabs</p>`;
            html += `<p><strong>Method:</strong> Composition Plan (Single cohesive track with seamless segues)</p>`;
            html += `<p><strong>Description:</strong> ${data.description || '28-second track (12s + 12s + 4s)'}</p>`;
            html += `<p><strong>Scenes:</strong> ${data.scene_count}</p>`;
            html += `<p><strong>Total Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="elevenlabs_28s_seamless.mp3" style="display: inline-block; background: #dc3545; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px; font-weight: bold;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusicElevenlabs3Chunk() {
          const sceneTypes = document.getElementById('sceneTypes').value.split(',').map(s => s.trim());
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating music with ElevenLabs 3-Chunk method (12s + 12s + 4s, ~60-90 seconds)...</div>';
          try {
            const data = await apiCall('/music/elevenlabs-3chunk', 'POST', {
              scene_types: sceneTypes,
              default_duration: 4.0
            });
            
            let html = '<div class="result success">';
            html += `<h3>🎵 ElevenLabs 3-Chunk Music Generated!</h3>`;
            html += `<p><strong>Provider:</strong> ElevenLabs</p>`;
            html += `<p><strong>Method:</strong> 3-Chunk (12s + 12s + 4s with fade)</p>`;
            html += `<p><strong>Chunk 1:</strong> ${data.chunks.chunk1}</p>`;
            html += `<p><strong>Chunk 2:</strong> ${data.chunks.chunk2}</p>`;
            html += `<p><strong>Chunk 3:</strong> ${data.chunks.chunk3}</p>`;
            html += `<p><strong>Total Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="elevenlabs_3chunk_28s.mp3" style="display: inline-block; background: #20c997; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px; font-weight: bold;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusicRapid() {
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating rapid music test (scenes 1-3, ~30-45 seconds)...</div>';
          try {
            const data = await apiCall('/music/rapid', 'POST', {
              default_duration: 4.0
            });
            
            let html = '<div class="result success">';
            html += `<h3>🎵 Rapid Music Test Complete!</h3>`;
            html += `<p><strong>Scenes:</strong> ${data.scene_count} (Hook, Bedroom, Vanity)</p>`;
            html += `<p><strong>Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="rapid_test_music.mp3" style="display: inline-block; background: #28a745; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusicChunk() {
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating 28-second chunk (single API call, no continuation, ~30-45 seconds)...</div>';
          try {
            const data = await apiCall('/music/chunk', 'POST', {
              default_duration: 28.0
            });
            
            let html = '<div class="result success">';
            html += `<h3>🎵 Chunk Music Generation Complete!</h3>`;
            html += `<p><strong>Method:</strong> Single 28-second generation (no continuation)</p>`;
            html += `<p><strong>Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="chunk_music_28s.mp3" style="display: inline-block; background: #28a745; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            if (data.combined_prompt) {
              html += '<details style="margin-top: 15px;"><summary>Combined Prompt</summary><pre style="white-space: pre-wrap; word-wrap: break-word;">' + data.combined_prompt + '</pre></details>';
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function testMusic3Chunk() {
          const result = document.getElementById('musicResult');
          result.innerHTML = '<div class="result">Generating 3-chunk music (12s + 12s + 4s with continuation, ~90-120 seconds)...</div>';
          try {
            const data = await apiCall('/music/3chunk', 'POST', {});
            
            let html = '<div class="result success">';
            html += `<h3>🎵 3-Chunk Music Generation Complete!</h3>`;
            html += `<p><strong>Method:</strong> 3 chunks with continuation (12s → 24s → 28s)</p>`;
            html += `<p><strong>Chunks:</strong> ${data.chunk_count}</p>`;
            html += `<p><strong>Total Duration:</strong> ${data.total_duration_seconds} seconds</p>`;
            html += `<p><strong>Size:</strong> ${(data.audio_size_bytes / 1024).toFixed(2)} KB</p>`;
            
            // Add download button if audio is available
            if (data.audio_base64) {
              const audioBlob = base64ToBlob(data.audio_base64, 'audio/mpeg');
              const audioUrl = URL.createObjectURL(audioBlob);
              html += `<p><a href="${audioUrl}" download="3chunk_music_28s.mp3" style="display: inline-block; background: #28a745; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; margin-top: 10px;">⬇ Download Music (MP3)</a></p>`;
              html += `<p><audio controls style="width: 100%; margin-top: 10px;"><source src="${audioUrl}" type="audio/mpeg">Your browser does not support the audio element.</audio></p>`;
            }
            
            // Show chunk details
            if (data.chunks) {
              html += '<details style="margin-top: 15px;"><summary>Chunk Details</summary>';
              html += `<p><strong>Chunk 1:</strong> ${data.chunks.chunk1.duration}s - ${data.chunks.chunk1.prompt.substring(0, 100)}...</p>`;
              html += `<p><strong>Chunk 2:</strong> ${data.chunks.chunk2.duration}s (continuation) - ${data.chunks.chunk2.prompt.substring(0, 100)}...</p>`;
              html += `<p><strong>Chunk 3:</strong> ${data.chunks.chunk3.duration}s (continuation) - ${data.chunks.chunk3.prompt.substring(0, 100)}...</p>`;
              html += '</details>';
            }
            
            html += '<details style="margin-top: 15px;"><summary>Full Response JSON</summary><pre>' + JSON.stringify(data, null, 2).replace(/"audio_base64":"[^"]+"/, '"audio_base64":"[base64 data - ' + (data.audio_base64 ? data.audio_base64.length : 0) + ' chars]..."') + '</pre></details>';
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        function base64ToBlob(base64, mimeType) {
          const byteCharacters = atob(base64);
          const byteNumbers = new Array(byteCharacters.length);
          for (let i = 0; i < byteCharacters.length; i++) {
            byteNumbers[i] = byteCharacters.charCodeAt(i);
          }
          const byteArray = new Uint8Array(byteNumbers);
          return new Blob([byteArray], { type: mimeType });
        }

        async function previewTextOverlay() {
          const text = document.getElementById('overlayText').value;
          const result = document.getElementById('overlayResult');
          result.innerHTML = '<div class="result">Loading preview...</div>';
          try {
            const data = await apiCall('/overlay/preview', 'POST', {
              text,
              options: { font_size: 48, position: 'bottom_center', color: 'white' }
            });
            result.innerHTML = `<div class="result success"><pre>${JSON.stringify(data, null, 2)}</pre></div>`;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function generateScript() {
          const propertyName = document.getElementById('propertyName').value;
          const result = document.getElementById('voiceoverResult');
          result.innerHTML = '<div class="result">Generating script...</div>';
          try {
            const data = await apiCall('/voiceover/script', 'POST', {
              property_details: {
                name: propertyName,
                type: 'luxury mountain retreat',
                features: ['infinity pool', 'mountain views', 'spa'],
                location: 'Aspen, Colorado'
              },
              scenes: [
                { title: 'Exterior', description: 'Pool area' },
                { title: 'Bedroom', description: 'Master suite' }
              ]
            });
            result.innerHTML = `<div class="result success"><pre>${JSON.stringify(data, null, 2)}</pre></div>`;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function loadCampaigns() {
          const result = document.getElementById('campaignsResult');
          result.innerHTML = '<div class="result">Loading...</div>';
          try {
            const data = await apiCall('/campaigns');
            result.innerHTML = `<div class="result success"><pre>${JSON.stringify(data, null, 2)}</pre></div>`;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function loadJobs() {
          const result = document.getElementById('jobsResult');
          result.innerHTML = '<div class="result">Loading...</div>';
          try {
            const status = document.getElementById('jobStatusFilter').value;
            const hasVideo = document.getElementById('hasVideoFilter').checked;
            const hasAudio = document.getElementById('hasAudioFilter').checked;
            
            let url = '/jobs?';
            if (status) url += `status=${status}&`;
            if (hasVideo) url += 'has_video=true&';
            if (hasAudio) url += 'has_audio=true&';
            
            const data = await apiCall(url.replace(/&$/, ''));
            
            // Format the output nicely with clickable links
            let html = '<div class="result success">';
            html += `<h3>Found ${data.count} job(s)</h3>`;
            
            if (data.jobs && data.jobs.length > 0) {
              html += '<table style="width: 100%; border-collapse: collapse; margin-top: 10px;">';
              html += '<tr style="background: #f0f0f0;"><th style="padding: 8px; text-align: left;">Job ID</th><th style="padding: 8px; text-align: left;">Status</th><th style="padding: 8px; text-align: left;">Scenes</th><th style="padding: 8px; text-align: left;">Video</th><th style="padding: 8px; text-align: left;">Audio</th><th style="padding: 8px; text-align: left;">Links</th></tr>';
              
              data.jobs.forEach(job => {
                html += '<tr style="border-bottom: 1px solid #ddd;">';
                html += `<td style="padding: 8px;">${job.id}</td>`;
                html += `<td style="padding: 8px;">${job.status}</td>`;
                html += `<td style="padding: 8px;">${job.scene_count}</td>`;
                html += `<td style="padding: 8px;">${job.has_video ? '✓ ' + (job.video_size_mb || 0) + ' MB' : '✗'}</td>`;
                html += `<td style="padding: 8px;">${job.has_audio ? '✓ ' + (job.audio_size_mb || 0) + ' MB' : '✗'}</td>`;
                html += '<td style="padding: 8px;">';
                if (job.video_url) html += `<a href="${job.video_url}" target="_blank" style="margin-right: 10px;">Video</a>`;
                if (job.audio_url) html += `<a href="${job.audio_url}" target="_blank" style="margin-right: 10px;">Audio</a>`;
                if (job.thumbnail_url) html += `<a href="${job.thumbnail_url}" target="_blank">Thumb</a>`;
                html += '</td></tr>';
              });
              
              html += '</table>';
              html += '<details style="margin-top: 15px;"><summary>Raw JSON</summary><pre>' + JSON.stringify(data, null, 2) + '</pre></details>';
            } else {
              html += '<p>No jobs found matching your criteria.</p>';
            }
            
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function loadPipelineConfig() {
          const result = document.getElementById('pipelineConfig');
          result.innerHTML = '<div class="result">Loading...</div>';
          try {
            const data = await apiCall('/pipeline/config');
            let html = '<div class="result success">';
            for (const [key, config] of Object.entries(data.config)) {
              html += `<div class="config-item">
                <span><strong>${key}</strong>: ${config.enabled ? '✓ Enabled' : '✗ Disabled'}</span>
                <label class="toggle">
                  <input type="checkbox" ${config.enabled ? 'checked' : ''} onchange="toggleStep('${key}', this.checked)">
                  <span class="slider"></span>
                </label>
              </div>`;
            }
            html += '</div>';
            result.innerHTML = html;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
        }

        async function toggleStep(step, enabled) {
          try {
            await apiCall('/pipeline/config', 'POST', {
              step,
              updates: { enabled }
            });
            console.log(`${step} ${enabled ? 'enabled' : 'disabled'}`);
          } catch (err) {
            alert('Failed to update: ' + err.message);
            loadPipelineConfig();
          }
        }
      </script>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html_content)
  end

  # Private helpers

  defp estimate_audio_duration(script) do
    # Rough estimate: 150 words per minute = 2.5 words per second
    word_count = String.split(script) |> length()
    max(word_count / 2.5, 1.0)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        try do
          {String.to_existing_atom(key), atomize_keys(value)}
        rescue
          ArgumentError -> {key, atomize_keys(value)}
        end

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(value), do: value

  defp enrich_scenes_with_assets(scenes, assets) do
    asset_map = Map.new(assets, fn asset ->
      {asset.id,
       %{
         id: asset.id,
         metadata: asset.metadata || %{},
         source_url: asset.source_url,
         asset_url: "/api/v3/assets/#{asset.id}/data"
       }}
    end)

    Enum.map(scenes, fn scene ->
      asset_ids = Map.get(scene, "asset_ids", [])

      selected_assets =
        asset_ids
        |> Enum.map(&Map.get(asset_map, &1))
        |> Enum.reject(&is_nil/1)

      Map.put(scene, "selected_assets", selected_assets)
    end)
  end

  defp scene_summary(scene) do
    %{
      title: scene["title"],
      duration: scene["duration"],
      music_style: scene["music_style"],
      music_energy: scene["music_energy"]
    }
  end

  defp build_music_prompt_preview(scene) do
    case {scene["music_description"], scene["music_style"], scene["music_energy"]} do
      {desc, style, energy} when not is_nil(desc) and not is_nil(style) ->
        "Luxury real estate showcase - #{desc}. Style: #{style}. Energy level: #{energy}. Instrumental, cinematic, high production quality."

      _ ->
        "Cinematic background music, professional and engaging, instrumental"
    end
  end

  @doc """
  POST /api/v3/testing/audio/temp-upload
  Uploads audio temporarily for Replicate continuation (returns URL via ngrok).
  
  Body: { "audio_base64": "..." } or binary audio data
  """
  def upload_temp_audio(conn, params) do
    # Generate a unique token for this audio
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    
    # Get audio blob from request
    audio_blob = cond do
      Map.has_key?(params, "audio_base64") ->
        Base.decode64!(params["audio_base64"])
      Map.has_key?(params, "audio") and is_binary(params["audio"]) ->
        params["audio"]
      true ->
        # Try to read from body
        case read_body(conn) do
          {:ok, body, _conn} when byte_size(body) > 0 -> body
          _ -> nil
        end
    end
    
    if audio_blob do
      # Store in ETS table (in-memory, temporary)
      :ets.insert(:temp_audio_store, {token, audio_blob, System.system_time(:second)})
      
      # Get public base URL (ngrok)
      base_url = Application.get_env(:backend, :public_base_url, "http://localhost:4000")
      audio_url = "#{base_url}/api/v3/testing/audio/temp/#{token}"
      
      json(conn, %{
        success: true,
        token: token,
        url: audio_url,
        size_bytes: byte_size(audio_blob),
        expires_in: "1 hour"
      })
    else
      conn
      |> put_status(:bad_request)
      |> json(%{success: false, error: "No audio data provided"})
    end
  end

  @doc """
  GET /api/v3/testing/audio/temp/:token
  Serves temporarily stored audio file for Replicate.
  """
  def serve_temp_audio(conn, %{"token" => token}) do
    case :ets.lookup(:temp_audio_store, token) do
      [{^token, audio_blob, uploaded_at}] ->
        # Check if expired (1 hour)
        age = System.system_time(:second) - uploaded_at
        if age > 3600 do
          :ets.delete(:temp_audio_store, token)
          conn
          |> put_status(:not_found)
          |> json(%{error: "Audio expired"})
        else
          conn
          |> put_resp_content_type("audio/mpeg")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("content-length", to_string(byte_size(audio_blob)))
          |> send_resp(200, audio_blob)
        end
      
      [] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Audio not found"})
    end
  end
end
