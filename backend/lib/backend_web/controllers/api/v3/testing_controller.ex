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

    options = %{
      duration: Map.get(scene_params, "duration", 4)
    }

    case MusicgenService.generate_scene_audio(scene_params, options) do
      {:ok, result} ->
        json(conn, %{
          success: true,
          scene_title: scene_params["title"],
          audio_size_bytes: byte_size(result.audio_blob),
          has_continuation_token: !is_nil(result.continuation_token),
          prompt_used: build_music_prompt_preview(scene_params)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

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
        json(conn, %{
          success: true,
          scene_count: length(scenes),
          audio_size_bytes: byte_size(final_audio_blob),
          total_duration_seconds: length(scenes) * default_duration,
          scenes: Enum.map(scenes, &scene_summary/1)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
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
    options = Map.get(params, "options", %{})

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
    options = Map.get(params, "options", %{})
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
    options = Map.get(params, "options", %{})

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
    property_details = Map.get(params, "property_details", %{})
    scenes = Map.get(params, "scenes", [])
    options = Map.get(params, "options", %{})

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
              <input type="number" id="campaignId" placeholder="123">
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
            <button onclick="testMusicGeneration()">Generate Music</button>
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
              campaign_id: parseInt(campaignId),
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
          result.innerHTML = '<div class="result">Generating music (this may take a minute)...</div>';
          try {
            const data = await apiCall('/music/from-templates', 'POST', {
              scene_types: sceneTypes,
              default_duration: 4.0
            });
            result.innerHTML = `<div class="result success"><pre>${JSON.stringify(data, null, 2)}</pre></div>`;
          } catch (err) {
            result.innerHTML = `<div class="result error">${err.message}</div>`;
          }
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
end
