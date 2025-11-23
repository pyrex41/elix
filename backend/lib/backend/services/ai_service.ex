defmodule Backend.Services.AiService do
  @moduledoc """
  Service module for interacting with AI APIs (xAI/Grok).
  Handles scene generation from campaign assets.
  """
  require Logger
  alias Backend.Templates.SceneTemplates

  @doc """
  Generates scene descriptions from campaign assets using xAI/Grok API.

  ## Parameters
    - assets: List of asset structs with blob_data or source_url
    - campaign_brief: String describing the campaign
    - job_type: :image_pairs or :property_photos
    - options: Additional options (property_types for property_photos)

  ## Returns
    - {:ok, scenes} where scenes is a list of scene maps
    - {:error, reason} on failure
  """
  def generate_scenes(assets, campaign_brief, job_type, options \\ %{}) do
    # Check if we should use mock data (no API key configured)
    case get_api_key() do
      nil ->
        Logger.info("[AiService] No xAI API key configured, using mock data")
        generate_mock_scenes(assets, job_type, options)

      api_key ->
        Logger.info("[AiService] Using xAI API to generate scenes")
        # For image_pairs, group assets and select best groups
        case job_type do
          :image_pairs ->
            call_xai_api_for_group_selection(assets, campaign_brief, options, api_key)

          _ ->
            call_xai_api(assets, campaign_brief, job_type, options, api_key)
        end
    end
  end

  @doc """
  Selects optimal image pairs for each scene type using LMM analysis.

  ## Parameters
    - assets: List of asset structs with metadata
    - campaign_brief: String describing the campaign
    - scene_count: Number of scenes to generate (defaults to 7)
    - options: Additional options (property_type, style preferences, etc.)

  ## Returns
    - {:ok, scenes} where each scene includes selected asset_ids for first/last frame
    - {:error, reason} on failure
  """
  def select_image_pairs_for_scenes(assets, campaign_brief, scene_count \\ 7, options \\ %{}) do
    case get_api_key() do
      nil ->
        Logger.info("[AiService] No xAI API key configured, using simple selection")
        simple_image_pair_selection(assets, scene_count)

      api_key ->
        Logger.info("[AiService] Using LMM for intelligent image pair selection")

        # Get scene templates for the requested count
        available_types = extract_scene_types_from_assets(assets)
        templates = SceneTemplates.adapt_to_scene_count(scene_count, available_types)

        # Call LMM to select best pairs for each scene
        call_xai_for_image_pair_selection(assets, campaign_brief, templates, options, api_key)
    end
  end

  # Private functions

  defp get_api_key do
    Application.get_env(:backend, :xai_api_key)
  end

  defp call_xai_api(assets, campaign_brief, job_type, options, api_key) do
    prompt = build_prompt(assets, campaign_brief, job_type, options)

    # xAI/Grok API endpoint
    url = "https://api.x.ai/v1/chat/completions"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "messages" => [
        %{
          "role" => "system",
          "content" => get_system_prompt(job_type)
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
        parse_ai_response(response_body, job_type)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[AiService] xAI API returned status #{status}: #{inspect(body)}")
        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[AiService] xAI API request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp call_xai_api_for_group_selection(assets, campaign_brief, options, api_key) do
    # Group assets by category
    grouped_assets = group_assets_by_category(assets)
    num_pairs = Map.get(options, "num_pairs", Map.get(options, :num_pairs, 4))

    Logger.info(
      "[AiService] Grouped assets into #{map_size(grouped_assets)} categories, requesting #{num_pairs} selections"
    )

    # Build prompt asking AI to select groups
    prompt = build_group_selection_prompt(grouped_assets, campaign_brief, num_pairs)

    url = "https://api.x.ai/v1/chat/completions"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "messages" => [
        %{
          "role" => "system",
          "content" => get_group_selection_system_prompt()
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
        parse_group_selection_response(response_body, grouped_assets, options)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[AiService] xAI API returned status #{status}: #{inspect(body)}")
        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[AiService] xAI API request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp get_system_prompt(:image_pairs) do
    """
    You are a creative video production assistant. Your task is to analyze image pairs and a campaign brief,
    then generate detailed scene descriptions for video production. Each scene should include:
    - A descriptive title
    - Detailed visual description
    - Duration in seconds
    - Transition type
    - Any text overlays or captions

    Return your response as a JSON array of scenes with the following structure:
    [
      {
        "title": "Scene title",
        "description": "Detailed visual description",
        "duration": 5,
        "transition": "fade|cut|dissolve",
        "text_overlay": "Optional text to display"
      }
    ]
    """
  end

  defp get_system_prompt(:property_photos) do
    """
    You are a real estate video production assistant. Your task is to analyze property photos and a campaign brief,
    then generate detailed scene descriptions for property showcase videos. Each scene should include:
    - A descriptive title
    - Detailed visual description
    - Duration in seconds
    - Transition type
    - Property feature highlights
    - Scene type (must match allowed property types)

    Return your response as a JSON array of scenes with the following structure:
    [
      {
        "title": "Scene title",
        "description": "Detailed visual description",
        "duration": 5,
        "transition": "fade|cut|dissolve",
        "scene_type": "exterior|interior|kitchen|bedroom|bathroom|living_room",
        "highlights": ["feature1", "feature2"]
      }
    ]
    """
  end

  defp build_prompt(assets, campaign_brief, job_type, options) do
    asset_count = length(assets)

    base_prompt = """
    Campaign Brief: #{campaign_brief}

    Number of assets provided: #{asset_count}

    Please analyze the provided assets and generate a storyboard with detailed scene descriptions.
    Each scene should flow naturally and align with the campaign brief.
    """

    case job_type do
      :property_photos ->
        property_types = Map.get(options, :property_types, [])

        """
        #{base_prompt}

        Property Types: #{Enum.join(property_types, ", ")}

        Ensure each scene type matches one of the allowed property types.
        """

      :image_pairs ->
        base_prompt
    end
  end

  defp parse_ai_response(response_body, job_type) do
    try do
      # Extract the content from the AI response
      content =
        response_body
        |> Map.get("choices", [])
        |> List.first()
        |> Map.get("message", %{})
        |> Map.get("content", "")

      # Try to extract JSON from the response
      scenes = extract_json_from_content(content)

      # Validate scenes based on job type
      case validate_scenes(scenes, job_type) do
        :ok ->
          {:ok, scenes}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[AiService] Failed to parse AI response: #{inspect(e)}")
        {:error, "Failed to parse AI response"}
    end
  end

  defp extract_json_from_content(content) do
    # Try to find JSON array in the content
    case Regex.run(~r/\[[\s\S]*\]/, content) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, scenes} when is_list(scenes) -> scenes
          _ -> []
        end

      _ ->
        # If no JSON array found, try to parse the whole content
        case Jason.decode(content) do
          {:ok, scenes} when is_list(scenes) -> scenes
          {:ok, %{"scenes" => scenes}} when is_list(scenes) -> scenes
          _ -> []
        end
    end
  end

  defp validate_scenes([], _job_type) do
    {:error, "No scenes generated"}
  end

  defp validate_scenes(scenes, :image_pairs) when is_list(scenes) do
    # Validate that each scene has required fields
    valid =
      Enum.all?(scenes, fn scene ->
        is_map(scene) and
          Map.has_key?(scene, "title") and
          Map.has_key?(scene, "description") and
          Map.has_key?(scene, "duration")
      end)

    if valid do
      :ok
    else
      {:error, "Invalid scene structure"}
    end
  end

  defp validate_scenes(scenes, :property_photos) when is_list(scenes) do
    # Validate that each scene has required fields including scene_type
    valid =
      Enum.all?(scenes, fn scene ->
        is_map(scene) and
          Map.has_key?(scene, "title") and
          Map.has_key?(scene, "description") and
          Map.has_key?(scene, "duration") and
          Map.has_key?(scene, "scene_type")
      end)

    if valid do
      :ok
    else
      {:error, "Invalid scene structure for property photos"}
    end
  end

  defp validate_scenes(_scenes, _job_type) do
    {:error, "Invalid scenes format"}
  end

  defp generate_mock_scenes(assets, :image_pairs, _options) do
    asset_count = length(assets)

    scenes =
      Enum.map(1..min(asset_count, 5), fn i ->
        %{
          "title" => "Scene #{i}",
          "description" =>
            "A dynamic scene showcasing the brand story with compelling visuals and smooth transitions.",
          "duration" => 5 + rem(i, 3),
          "transition" => Enum.at(["fade", "cut", "dissolve"], rem(i, 3)),
          "text_overlay" => if(rem(i, 2) == 0, do: "Key Message #{i}", else: nil)
        }
      end)

    {:ok, scenes}
  end

  defp generate_mock_scenes(assets, :property_photos, options) do
    asset_count = length(assets)
    property_types = Map.get(options, :property_types, ["exterior", "interior"])

    scenes =
      Enum.map(1..min(asset_count, 5), fn i ->
        scene_type = Enum.at(property_types, rem(i, length(property_types)))

        %{
          "title" => "#{String.capitalize(scene_type)} View #{i}",
          "description" =>
            "Stunning #{scene_type} featuring premium finishes and thoughtful design details.",
          "duration" => 4 + rem(i, 4),
          "transition" => Enum.at(["fade", "cut", "dissolve"], rem(i, 3)),
          "scene_type" => scene_type,
          "highlights" => ["Modern design", "Premium quality", "Spacious layout"]
        }
      end)

    {:ok, scenes}
  end

  # Group selection helpers for image_pairs

  defp get_group_selection_system_prompt do
    """
    You are a luxury real estate marketing expert. Your task is to select the best room/area groups
    for a high-end property social media video ad.

    You will be given a list of available room/area groups (Kitchen, Bedroom, Exterior, etc.) with
    the number of photos available in each group.

    Select the groups that will create the most compelling luxury property showcase for social media.
    Prioritize variety and visual impact.

    Return ONLY a JSON array of the selected group names, nothing else.
    Example: ["Showcase", "Exterior 1", "Living Room 1", "Kitchen 1"]
    """
  end

  defp build_group_selection_prompt(grouped_assets, campaign_brief, num_pairs) do
    # Build list of available groups with counts
    groups_summary =
      grouped_assets
      |> Enum.map(fn {group_name, assets} ->
        "- #{group_name} (#{length(assets)} photos)"
      end)
      |> Enum.join("\n")

    """
    Campaign Brief: #{campaign_brief}

    Available asset groups for this luxury property:
    #{groups_summary}

    Please select exactly #{num_pairs} groups that would create the best luxury property social media ad.
    Consider variety, visual appeal, and storytelling flow.

    Return a JSON array with #{num_pairs} group names from the list above.
    """
  end

  defp group_assets_by_category(assets) do
    assets
    |> Enum.group_by(fn asset ->
      case asset.metadata do
        %{"original_name" => name} when is_binary(name) ->
          extract_group_name(name)

        %{} ->
          "Uncategorized"

        _ ->
          "Uncategorized"
      end
    end)
    |> Map.reject(fn {_key, values} -> length(values) < 2 end)
  end

  defp extract_group_name(asset_name) do
    # Strip the last number from asset name
    # "Showcase 1" -> "Showcase"
    # "Exterior 1 2" -> "Exterior 1"
    # "Kitchen 1 10" -> "Kitchen 1"
    asset_name
    |> String.trim()
    |> String.split()
    |> Enum.reverse()
    |> case do
      [last | rest] ->
        # Check if last part is a number
        case Integer.parse(last) do
          {_num, ""} -> rest |> Enum.reverse() |> Enum.join(" ")
          _ -> asset_name
        end

      _ ->
        asset_name
    end
  end

  defp parse_group_selection_response(response_body, grouped_assets, options) do
    try do
      # Extract the content from the AI response
      content =
        response_body
        |> Map.get("choices", [])
        |> List.first()
        |> Map.get("message", %{})
        |> Map.get("content", "")

      Logger.info("[AiService] AI response: #{content}")

      # Extract JSON array from response
      selected_groups =
        case Regex.run(~r/\[[\s\S]*?\]/, content) do
          [json_str] ->
            case Jason.decode(json_str) do
              {:ok, groups} when is_list(groups) -> groups
              _ -> []
            end

          _ ->
            []
        end

      Logger.info("[AiService] Selected groups: #{inspect(selected_groups)}")

      # Build scenes from selected groups
      clip_duration = Map.get(options, "clip_duration", Map.get(options, :clip_duration, 5))

      scenes =
        selected_groups
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {group_name, _index} ->
          case Map.get(grouped_assets, group_name) do
            nil ->
              Logger.warning("[AiService] Group '#{group_name}' not found in assets")
              []

            group_assets ->
              # Take first 2 images from this group
              pair_assets = Enum.take(group_assets, 2)

              if length(pair_assets) >= 2 do
                [
                  %{
                    "title" => "#{group_name} Showcase",
                    "description" => "Luxury #{group_name} featuring premium finishes and design",
                    "duration" => clip_duration,
                    "transition" => "fade",
                    "group_name" => group_name,
                    "asset_ids" => Enum.map(pair_assets, & &1.id)
                  }
                ]
              else
                Logger.warning("[AiService] Group '#{group_name}' has less than 2 images")
                []
              end
          end
        end)

      if length(scenes) > 0 do
        {:ok, scenes}
      else
        {:error, "No valid scenes generated from selected groups"}
      end
    rescue
      e ->
        Logger.error("[AiService] Failed to parse group selection response: #{inspect(e)}")
        {:error, "Failed to parse AI response"}
    end
  end

  # Image pair selection helpers

  defp extract_scene_types_from_assets(assets) do
    assets
    |> Enum.flat_map(fn asset ->
      case asset.metadata do
        %{"scene_type" => type} when is_binary(type) -> [type]
        %{"tags" => tags} when is_list(tags) -> tags
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp call_xai_for_image_pair_selection(assets, campaign_brief, templates, options, api_key) do
    # Build detailed prompt for image selection
    prompt = build_image_pair_selection_prompt(assets, campaign_brief, templates, options)

    url = "https://api.x.ai/v1/chat/completions"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "messages" => [
        %{
          "role" => "system",
          "content" => get_image_pair_selection_system_prompt()
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
        parse_image_pair_selection_response(response_body, templates, assets)

      {:ok, %{status: status, body: body}} ->
        Logger.error("[AiService] xAI API returned status #{status}: #{inspect(body)}")
        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[AiService] xAI API request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp get_image_pair_selection_system_prompt do
    """
    You are an expert luxury real estate video production assistant specializing in selecting
    the perfect image pairs for cinematic property showcase videos.

    Your task: Analyze property photos with their metadata and select the best FIRST and LAST
    image for each scene type to create smooth, cinematic transitions.

    For each scene type, you must select:
    1. FIRST image: The starting frame for the video transition
    2. LAST image: The ending frame for the video transition

    Selection criteria:
    - Images must match the scene type (e.g., bedroom photos for bedroom scene)
    - FIRST and LAST images should have complementary composition for smooth camera movement
    - Consider lighting, angle, and visual continuity
    - Prioritize high-quality, well-lit images
    - Ensure variety across all scenes (don't reuse same images)

    Return ONLY a JSON array with this structure:
    [
      {
        "scene_type": "hook",
        "first_image_id": "uuid-of-first-image",
        "last_image_id": "uuid-of-last-image",
        "reasoning": "Brief explanation of why these images work well together"
      }
    ]
    """
  end

  defp build_image_pair_selection_prompt(assets, campaign_brief, templates, _options) do
    # Build asset catalog with metadata
    asset_catalog =
      assets
      |> Enum.map(fn asset ->
        metadata_str =
          case asset.metadata do
            %{} = meta ->
              meta
              |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
              |> Enum.join(", ")

            _ ->
              "No metadata"
          end

        """
        - ID: #{asset.id}
          Type: #{asset.type}
          Metadata: {#{metadata_str}}
        """
      end)
      |> Enum.join("\n")

    # Build scene type requirements
    scene_requirements =
      templates
      |> Enum.map(fn template ->
        criteria = template.asset_criteria

        """
        Scene #{template.order}: #{template.title} (#{template.subtitle})
        - Type: #{template.type}
        - Duration: #{template.default_duration}s
        - Camera Movement: #{template.camera_movement}
        - Looking for: #{Enum.join(criteria.keywords, ", ")}
        - Scene types: #{Enum.join(criteria.scene_types, ", ")}
        """
      end)
      |> Enum.join("\n\n")

    """
    Campaign Brief: #{campaign_brief}

    AVAILABLE IMAGES (#{length(assets)} total):
    #{asset_catalog}

    SCENE REQUIREMENTS (#{length(templates)} scenes):
    #{scene_requirements}

    Please analyze all available images and select the best FIRST and LAST image for each scene type.
    Each image should only be used once across all scenes.
    Ensure smooth visual flow and narrative progression throughout the video.
    """
  end

  defp parse_image_pair_selection_response(response_body, templates, _assets) do
    try do
      # Extract the content from the AI response
      content =
        response_body
        |> Map.get("choices", [])
        |> List.first()
        |> Map.get("message", %{})
        |> Map.get("content", "")

      Logger.info("[AiService] Image pair selection response received")

      # Extract JSON array from response
      selections =
        case Regex.run(~r/\[[\s\S]*?\]/, content) do
          [json_str] ->
            case Jason.decode(json_str) do
              {:ok, sels} when is_list(sels) -> sels
              _ -> []
            end

          _ ->
            []
        end

      Logger.info("[AiService] Parsed #{length(selections)} scene selections")

      # Build scenes from selections and templates
      scenes =
        Enum.zip(templates, selections)
        |> Enum.map(fn {template, selection} ->
          video_prompt = template.video_prompt |> String.trim()

          %{
            "title" => template.title,
            "description" => video_prompt,
            "prompt" => video_prompt,
            "duration" => template.default_duration,
            "time_start" => template.time_start,
            "time_end" => template.time_end,
            "transition" => "fade",
            "scene_type" => to_string(template.type),
            "camera_movement" => to_string(template.camera_movement),
            "motion_goal" => template.motion_goal,
            "asset_ids" => [
              Map.get(selection, "first_image_id"),
              Map.get(selection, "last_image_id")
            ],
            "music_description" => template.music_description,
            "music_style" => template.music_style,
            "music_energy" => template.music_energy,
            "selection_reasoning" => Map.get(selection, "reasoning", "")
          }
        end)

      {:ok, scenes}
    rescue
      e ->
        Logger.error("[AiService] Failed to parse image pair selection response: #{inspect(e)}")
        {:error, "Failed to parse AI response"}
    end
  end

  defp simple_image_pair_selection(assets, scene_count) do
    # Fallback: Simple selection when no API key is available
    templates = SceneTemplates.adapt_to_scene_count(scene_count)

    scenes =
      templates
      |> Enum.with_index()
      |> Enum.map(fn {template, idx} ->
        # Simple strategy: Distribute assets evenly across scenes
        first_idx = rem(idx * 2, length(assets))
        last_idx = rem(idx * 2 + 1, length(assets))

        first_asset = Enum.at(assets, first_idx)
        last_asset = Enum.at(assets, last_idx)

        video_prompt = template.video_prompt |> String.trim()

        %{
          "title" => template.title,
          "description" => video_prompt,
          "prompt" => video_prompt,
          "duration" => template.default_duration,
          "time_start" => template.time_start,
          "time_end" => template.time_end,
          "transition" => "fade",
          "scene_type" => to_string(template.type),
          "camera_movement" => to_string(template.camera_movement),
          "motion_goal" => template.motion_goal,
          "asset_ids" => [first_asset.id, last_asset.id],
          "music_description" => template.music_description,
          "music_style" => template.music_style,
          "music_energy" => template.music_energy
        }
      end)

    {:ok, scenes}
  end
end
