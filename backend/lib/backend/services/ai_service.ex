defmodule Backend.Services.AiService do
  @moduledoc """
  Service module for interacting with AI APIs (xAI/Grok).
  Handles scene generation from campaign assets.
  """
  require Logger
  alias Backend.Templates.SceneTemplates

  @group_assignment_limit 40
  @group_selection_concurrency 4
  @max_ai_retries 3

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

        request_fun =
          case job_type do
            :image_pairs ->
              fn attempt ->
                call_xai_api_for_group_selection(assets, campaign_brief, options, api_key, attempt)
              end

            _ ->
              fn attempt ->
                call_xai_api(assets, campaign_brief, job_type, options, api_key, attempt)
              end
          end

        case retry_xai(request_fun) do
          {:ok, scenes} ->
            {:ok, scenes}

          {:error, "No scenes generated"} ->
            Logger.warning(
              "[AiService] AI returned no scenes (job_type=#{job_type}). Falling back to template scenes."
            )

            generate_mock_scenes(assets, job_type, options)

          {:error, reason} ->
            {:error, reason}
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

        grouped_assets =
          assets
          |> group_assets_by_category()
          |> Map.reject(fn {_name, group_assets} -> length(group_assets) < 2 end)

        case call_xai_for_grouped_image_selection(
               assets,
               grouped_assets,
               campaign_brief,
               templates,
               options,
               api_key
             ) do
          {:ok, scenes} ->
            {:ok, scenes}

          {:error, reason} ->
            Logger.warning(
              "[AiService] Grouped image selection failed (#{inspect(reason)}), falling back to legacy prompt"
            )

            call_xai_for_image_pair_selection(assets, campaign_brief, templates, options, api_key)
        end
    end
  end

  # Private functions

  defp get_api_key do
    Application.get_env(:backend, :xai_api_key)
  end

  defp call_xai_api(assets, campaign_brief, job_type, options, api_key, attempt) do
    prompt = build_prompt(assets, campaign_brief, job_type, options)
    system_prompt = get_system_prompt(job_type)

    # Log the meta-prompt that generates clip prompts
    Logger.info("[AiService] ========== META-PROMPT FOR SCENE GENERATION ==========")
    Logger.info("[AiService] Job type: #{job_type}")
    Logger.info("[AiService] Options: #{inspect(options)}")
    Logger.info("[AiService] System prompt:\n#{system_prompt}")
    Logger.info("[AiService] User prompt:\n#{prompt}")
    Logger.info("[AiService] ========== END META-PROMPT ==========")

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
          "content" => system_prompt
        },
        %{
          "role" => "user",
          "content" => prompt
        }
      ],
      "model" => "grok-4-1-fast-non-reasoning",
      "stream" => false,
      "temperature" => 0.7,
      "response_format" => structured_response_format(job_type)
    }

    case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_ai_response(response_body, job_type)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[AiService] xAI API returned status #{status} on attempt #{attempt}: #{inspect(body)}"
        )
        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error(
          "[AiService] xAI API request failed on attempt #{attempt}: #{inspect(exception)}"
        )
        {:error, Exception.message(exception)}
    end
  end

  defp call_xai_api_for_group_selection(assets, campaign_brief, options, api_key, attempt) do
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
      "temperature" => 0.7,
      "response_format" => grouped_selection_response_format()
    }

    case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_group_selection_response(response_body, grouped_assets, options)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[AiService] xAI API returned status #{status} on attempt #{attempt}: #{inspect(body)}"
        )
        {:error, "API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error(
          "[AiService] xAI API request failed on attempt #{attempt}: #{inspect(exception)}"
        )
        {:error, Exception.message(exception)}
    end
  end

  defp get_system_prompt(:image_pairs) do
    """
    You are a creative video production assistant. Your task is to analyze image pairs and a campaign brief,
    then generate detailed scene descriptions for video production. Each scene should include:
    - A descriptive title
    - Detailed visual description with GENTLE, GRADUAL camera movements
    - Duration in seconds
    - Transition type (prefer smooth transitions like fade or dissolve)
    - Any text overlays or captions

    CAMERA MOVEMENT GUIDELINES:
    - All pans must be SLOW and GENTLE (e.g., "slow pan", "gentle pan", "gradual pan")
    - All zooms must be SUBTLE and GRADUAL (e.g., "subtle zoom", "gentle zoom", "slow push in")
    - Avoid rapid, jarring, or dramatic camera movements
    - Prefer smooth, elegant motions that feel cinematic and professional
    - Use descriptors like: gentle, slow, gradual, subtle, smooth, elegant, soft

    Return your response as a JSON array of scenes with the following structure:
    [
      {
        "title": "Scene title",
        "description": "Detailed visual description with gentle camera movement",
        "duration": 5,
        "transition": "fade|dissolve|cut",
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
    - Detailed visual description with GENTLE, GRADUAL camera movements
    - Duration in seconds
    - Transition type (prefer smooth transitions like fade or dissolve)
    - Property feature highlights
    - Scene type (must match allowed property types)

    CAMERA MOVEMENT GUIDELINES:
    - All pans must be SLOW and GENTLE (e.g., "slow pan", "gentle pan", "gradual pan")
    - All zooms must be SUBTLE and GRADUAL (e.g., "subtle zoom", "gentle zoom", "slow push in")
    - Avoid rapid, jarring, or dramatic camera movements
    - Prefer smooth, elegant motions that feel cinematic and professional
    - Use descriptors like: gentle, slow, gradual, subtle, smooth, elegant, soft

    Return your response as a JSON array of scenes with the following structure:
    [
      {
        "title": "Scene title",
        "description": "Detailed visual description with gentle camera movement",
        "duration": 5,
        "transition": "fade|dissolve|cut",
        "scene_type": "exterior|interior|kitchen|bedroom|bathroom|living_room",
        "highlights": ["feature1", "feature2"]
      }
    ]
    """
  end

  defp build_prompt(assets, campaign_brief, job_type, options) do
    asset_count = length(assets)
    num_scenes = Map.get(options, :num_scenes, 7)
    clip_duration = Map.get(options, :clip_duration, 4)
    target_total_duration = num_scenes * clip_duration

    duration_guidance = """

    IMPORTANT Duration Constraints:
    - Generate exactly #{num_scenes} scenes
    - Each scene should be approximately #{clip_duration} seconds long
    - Target total duration: #{target_total_duration} seconds
    - Keep individual scene durations close to #{clip_duration} seconds (between #{clip_duration - 1} and #{clip_duration + 2} seconds)
    """

    base_prompt = """
    Campaign Brief: #{campaign_brief}

    Number of assets provided: #{asset_count}

    Please analyze the provided assets and generate a storyboard with detailed scene descriptions.
    Each scene should flow naturally and align with the campaign brief.
    #{duration_guidance}
    """

    structured = structured_output_instructions(job_type)

    case job_type do
      :property_photos ->
        property_types = Map.get(options, :property_types, [])

        """
        #{base_prompt}

        Property Types: #{Enum.join(property_types, ", ")}

        Ensure each scene type matches one of the allowed property types.

        #{structured}
        """

      :image_pairs ->
        """
        #{base_prompt}

        #{structured}
        """
    end
  end

  defp structured_output_instructions(:image_pairs) do
    """
    Structured Output Requirements:
    - Respond ONLY with a JSON array (no markdown, code fences, or prose).
    - Each element must include: "title" (string), "description" (string), "duration" (integer seconds), "transition" (string), and "scene_type" (string describing the focus of the scene).
    - Duration must be between 3 and 12 seconds. Use whole numbers.
    - Do not include any additional commentary outside the JSON array.
    """
  end

  defp structured_output_instructions(:property_photos) do
    """
    Structured Output Requirements:
    - Respond ONLY with a JSON array (no markdown, code fences, or prose).
    - Each element must include: "title" (string), "description" (string), "duration" (integer seconds), "transition" (string), and "scene_type" (string that matches one of the provided property types).
    - You may include optional arrays like "highlights" when useful, but stay within valid JSON.
    - Duration must be between 3 and 12 seconds. Use whole numbers.
    """
  end

  defp structured_output_instructions(_), do: structured_output_instructions(:image_pairs)

  defp structured_response_format(job_type) do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "scenes",
        "schema" => %{
          "type" => "array",
          "items" => scene_schema(job_type)
        }
      }
    }
  end

  defp grouped_selection_response_format do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "group_pairs",
        "schema" => %{
          "type" => "array",
          "items" => %{ "type" => "string" }
        }
      }
    }
  end

  defp scene_schema(:property_photos) do
    %{
      "type" => "object",
      "properties" =>
        common_scene_properties()
        |> Map.merge(%{
          "scene_type" => %{ "type" => "string" },
          "highlights" => %{ "type" => "array", "items" => %{ "type" => "string" } }
        }),
      "required" => ["title", "description", "duration", "transition", "scene_type"],
      "additionalProperties" => true
    }
  end

  defp scene_schema(_job_type) do
    %{
      "type" => "object",
      "properties" =>
        common_scene_properties()
        |> Map.put("scene_type", %{ "type" => "string" }),
      "required" => ["title", "description", "duration", "transition", "scene_type"],
      "additionalProperties" => true
    }
  end

  defp common_scene_properties do
    %{
      "title" => %{ "type" => "string" },
      "description" => %{ "type" => "string" },
      "duration" => %{ "type" => "integer" },
      "transition" => %{ "type" => "string" }
    }
  end

  defp parse_ai_response(response_body, job_type) do
    try do
      # Extract the content from the AI response
      content = extract_message_content(response_body)

      # Try to extract JSON from the response
      scenes = extract_json_from_content(content)
      log_scene_parse(content, scenes)

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

  defp log_scene_parse(content, scenes) do
    if scenes == [] do
      preview =
        content
        |> to_string()
        |> String.slice(0, 500)
        |> String.replace("\n", " ")

      Logger.warning(
        "[AiService] Parsed AI response but found no scenes. Content preview: #{preview}"
      )
    else
      # Log each generated scene with its prompt for debugging
      Logger.info("[AiService] ========== GENERATED SCENES (#{length(scenes)}) ==========")

      scenes
      |> Enum.with_index(1)
      |> Enum.each(fn {scene, index} ->
        title = Map.get(scene, "title", "Untitled")
        description = Map.get(scene, "description", "No description")
        duration = Map.get(scene, "duration", "?")
        scene_type = Map.get(scene, "scene_type", "unknown")

        Logger.info(
          "[AiService] Scene #{index}: [#{scene_type}] \"#{title}\" (#{duration}s)\n  Prompt: #{description}"
        )
      end)

      total_duration = Enum.reduce(scenes, 0, fn s, acc -> acc + (Map.get(s, "duration") || 0) end)
      Logger.info("[AiService] Total duration: #{total_duration}s")
      Logger.info("[AiService] ========== END GENERATED SCENES ==========")
    end
  end

  defp generate_mock_scenes(assets, :image_pairs, options) do
    scene_count =
      Map.get(options, :num_pairs) ||
        Map.get(options, "num_pairs") ||
        length(assets)

    simple_image_pair_selection(assets, scene_count)
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
    Example: ["Exterior 1", "Living Room 1", "Kitchen 1", "Bedroom 1"]
    """
  end

  defp build_group_selection_prompt(grouped_assets, campaign_brief, num_pairs) do
    # Build list of available groups with counts, excluding "Showcase" sections
    groups_summary =
      grouped_assets
      |> Enum.reject(fn {group_name, _assets} -> group_name == "Showcase" end)
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
      cond do
        is_list(asset.tags) and asset.tags != [] ->
          asset.tags
          |> List.first()
          |> extract_group_name()

        is_binary(asset.name) and asset.name != "" ->
          extract_group_name(asset.name)

        match?(%{"original_name" => name} when is_binary(name), asset.metadata || %{}) ->
          extract_group_name(asset.metadata["original_name"])

        match?(%{"originalName" => name} when is_binary(name), asset.metadata || %{}) ->
          extract_group_name(asset.metadata["originalName"])

        true ->
          "Uncategorized"
      end
    end)
    |> Map.reject(fn {_key, values} -> length(values) < 2 end)
  end

  defp extract_group_name(nil), do: "Uncategorized"

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
      content = extract_message_content(response_body)

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

  defp call_xai_for_grouped_image_selection(
         _assets,
         grouped_assets,
         _campaign_brief,
         _templates,
         _options,
         _api_key
       )
       when grouped_assets == %{} do
    {:error, :no_grouped_assets}
  end

  defp call_xai_for_grouped_image_selection(
         _assets,
         grouped_assets,
         campaign_brief,
         templates,
         options,
         api_key
       ) do
    # Exclude "Showcase" sections from available groups
    limited_groups =
      grouped_assets
      |> Enum.reject(fn {group_name, _assets} -> group_name == "Showcase" end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.take(@group_assignment_limit)

    with {:ok, assignments} <-
           assign_groups_to_scenes(templates, limited_groups, campaign_brief, api_key),
         {:ok, scene_jobs} <- build_scene_group_jobs(templates, assignments, grouped_assets),
         {:ok, selections} <-
           select_images_for_scene_jobs(scene_jobs, campaign_brief, options, api_key) do
      {:ok, build_scenes_from_grouped_selection(templates, selections)}
    else
      {:error, reason} ->
        Logger.warning("[AiService] Grouped pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp assign_groups_to_scenes(_templates, [], _campaign_brief, _api_key) do
    {:error, :no_groups_available}
  end

  defp assign_groups_to_scenes(templates, grouped_assets, campaign_brief, api_key) do
    prompt = build_group_assignment_prompt(templates, grouped_assets, campaign_brief)

    body = %{
      "messages" => [
        %{
          "role" => "system",
          "content" => get_group_assignment_system_prompt()
        },
        %{
          "role" => "user",
          "content" => prompt
        }
      ],
      "model" => "grok-4-1-fast-non-reasoning",
      "stream" => false,
      "temperature" => 0.2
    }

    case Req.post("https://api.x.ai/v1/chat/completions",
           json: body,
           headers: [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/json"}
           ],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_group_assignment_response(response_body, templates)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[AiService] Group assignment failed with status #{status}: #{inspect(body)}"
        )

        {:error, "Group assignment failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[AiService] Group assignment request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp get_group_assignment_system_prompt do
    """
    You orchestrate a luxury property video storyboard. Marketing already defined scene templates
    (hook, bedroom, bathroom, etc.). Your job is to map each scene template to the best available
    photo group so later steps can stay within that group.

    Rules:
    - Use only the groups that are listed.
    - Prefer groups whose tags/metadata match the scene type and camera direction.
    - Ensure the group has at least 2 photos.
    - Provide good variety (don't pick seven bedrooms unless required).

    Output contract:
    Return a JSON array where each item looks like:
    {
      "scene_type": "hook",
      "group_name": "Exterior 1"
    }

    Include every scene in the storyboard (same order as provided).
    """
  end

  defp build_group_assignment_prompt(templates, grouped_assets, campaign_brief) do
    scenes =
      templates
      |> Enum.map(&format_scene_requirement/1)
      |> Enum.join("\n\n")

    # Exclude "Showcase" sections from the available groups
    groups =
      grouped_assets
      |> Enum.reject(fn {group_name, _assets} -> group_name == "Showcase" end)
      |> Enum.map(&format_group_summary/1)
      |> Enum.join("\n\n")

    """
    Campaign Brief:
    #{campaign_brief || "N/A"}

    Scene templates needing coverage:
    #{scenes}

    Available photo groups (choose exactly one per scene, keep pairs within a group):
    #{groups}

    Respond with JSON only. Each scene_type from the list above must map to one of the provided group names.
    If a perfect match does not exist, pick the closest viable group that still has at least 2 photos.
    """
  end

  defp format_group_summary({group_name, assets}) do
    tags = extract_scene_types_from_assets(assets)
    highlights = group_metadata_highlights(assets)

    """
    Group: #{group_name}
      • image_count: #{length(assets)}
      • dominant_tags: #{format_list(tags)}
      • metadata_highlights: #{format_list(highlights)}
    """
  end

  defp group_metadata_highlights(assets) do
    assets
    |> Enum.flat_map(fn asset ->
      metadata = asset.metadata || %{}

      Map.take(metadata, ["scene_type", "room_type", "view", "style", "keywords"])
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    end)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp parse_group_assignment_response(response_body, templates) do
    scene_keys = Enum.map(templates, &to_string(&1.type))

    content = extract_message_content(response_body)

    case extract_json_array_from_content(content) do
      {:ok, array} ->
        assignments =
          array
          |> Enum.reduce(%{}, fn
            %{"scene_type" => scene_type, "group_name" => group_name}, acc
            when is_binary(scene_type) and is_binary(group_name) ->
              if scene_type in scene_keys do
                Map.put_new(acc, scene_type, group_name)
              else
                acc
              end

            _item, acc ->
              acc
          end)

        {:ok, assignments}

      {:error, reason} ->
        Logger.error("[AiService] Failed parsing group assignment JSON: #{inspect(reason)}")
        {:error, :invalid_group_assignment}
    end
  end

  defp build_scene_group_jobs(templates, assignments, grouped_assets) do
    templates
    |> Enum.reduce_while({[], MapSet.new()}, fn template, {acc, used_groups} ->
      scene_key = to_string(template.type)
      preferred_group = Map.get(assignments, scene_key)

      case pick_group_for_scene(template, preferred_group, grouped_assets, used_groups) do
        {:ok, group_name, assets, updated_used} ->
          job = %{template: template, group_name: group_name, assets: assets}
          {:cont, {[job | acc], updated_used}}

        {:error, reason} ->
          {:halt, {:error, {reason, scene_key}}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {jobs, _used} -> {:ok, Enum.reverse(jobs)}
    end
  end

  defp pick_group_for_scene(template, group_name, grouped_assets, used_groups)
       when is_binary(group_name) do
    case Map.get(grouped_assets, group_name) do
      nil ->
        select_best_group(template, grouped_assets, used_groups, true)

      assets when length(assets) >= 2 ->
        {:ok, group_name, assets, MapSet.put(used_groups, group_name)}

      _ ->
        select_best_group(template, grouped_assets, used_groups, true)
    end
  end

  defp pick_group_for_scene(template, _preferred_group, grouped_assets, used_groups) do
    case select_best_group(template, grouped_assets, used_groups, true) do
      {:ok, name, assets} ->
        {:ok, name, assets, MapSet.put(used_groups, name)}

      :none ->
        case select_best_group(template, grouped_assets, used_groups, false) do
          {:ok, name, assets} ->
            {:ok, name, assets, used_groups}

          :none ->
            {:error, :no_group_available}
        end
    end
  end

  defp select_best_group(template, grouped_assets, used_groups, unused_only) do
    grouped_assets
    |> Enum.flat_map(fn {name, assets} ->
      cond do
        length(assets) < 2 ->
          []

        unused_only and MapSet.member?(used_groups, name) ->
          []

        true ->
          score =
            case template do
              nil -> length(assets)
              _ -> score_group_match(template, assets)
            end

          [{name, assets, score}]
      end
    end)
    |> Enum.sort_by(fn {_name, _assets, score} -> score end, :desc)
    |> List.first()
    |> case do
      {name, assets, _score} -> {:ok, name, assets}
      nil -> :none
    end
  end

  defp score_group_match(template, assets) do
    criteria = template.asset_criteria || %{}
    terms = group_terms_from_assets(assets)

    base =
      0
      |> maybe_add_score(terms, criteria[:scene_types], 8)
      |> maybe_add_score(terms, criteria[:preferred_tags], 5)
      |> maybe_add_score(terms, criteria[:keywords], 3)

    base + min(length(assets), 5)
  end

  defp maybe_add_score(score, _terms, nil, _addition), do: score

  defp maybe_add_score(score, terms, list, addition) do
    normalized =
      list
      |> Enum.map(&normalize_term/1)
      |> Enum.reject(&(&1 == ""))

    if Enum.any?(normalized, &MapSet.member?(terms, &1)) do
      score + addition
    else
      score
    end
  end

  defp group_terms_from_assets(assets) do
    assets
    |> Enum.flat_map(fn asset ->
      metadata = asset.metadata || %{}

      tags =
        cond do
          is_list(asset.tags) -> asset.tags
          is_binary(asset.tags) -> [asset.tags]
          true -> []
        end

      meta_tags =
        case metadata do
          %{"tags" => meta_list} when is_list(meta_list) ->
            meta_list

          %{"tags" => meta_json} when is_binary(meta_json) ->
            case Jason.decode(meta_json) do
              {:ok, decoded} when is_list(decoded) -> decoded
              _ -> []
            end

          _ ->
            []
        end

      keywords =
        case metadata do
          %{"keywords" => kw_list} when is_list(kw_list) ->
            kw_list

          %{"keywords" => kw_string} when is_binary(kw_string) ->
            kw_string |> String.split(",", trim: true)

          _ ->
            []
        end

      scene_type =
        case metadata["scene_type"] do
          value when is_binary(value) -> [value]
          _ -> []
        end

      room_type =
        case metadata["room_type"] do
          value when is_binary(value) -> [value]
          _ -> []
        end

      tags ++ meta_tags ++ keywords ++ scene_type ++ room_type
    end)
    |> Enum.map(&normalize_term/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_term(term) when is_binary(term), do: term |> String.trim() |> String.downcase()
  defp normalize_term(term) when is_atom(term), do: term |> Atom.to_string() |> normalize_term()
  defp normalize_term(_), do: ""

  defp select_images_for_scene_jobs(scene_jobs, campaign_brief, options, api_key) do
    scene_jobs
    |> Task.async_stream(
      fn %{template: template, group_name: group_name, assets: assets} ->
        select_images_for_scene_from_group(
          template,
          group_name,
          assets,
          campaign_brief,
          options,
          api_key
        )
      end,
      max_concurrency: @group_selection_concurrency,
      timeout: 90_000
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, selection}}, {:ok, acc} ->
        {:cont, {:ok, [selection | acc]}}

      {:ok, {:error, reason}}, _ ->
        {:halt, {:error, reason}}

      {:exit, reason}, _ ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, selections} -> {:ok, Enum.reverse(selections)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_images_for_scene_from_group(
         template,
         group_name,
         assets,
         campaign_brief,
         options,
         api_key
       ) do
    prompt = build_single_group_scene_prompt(template, group_name, assets, campaign_brief)

    body = %{
      "messages" => [
        %{
          "role" => "system",
          "content" => get_single_group_selection_system_prompt()
        },
        %{
          "role" => "user",
          "content" => prompt
        }
      ],
      "model" => Map.get(options, :video_pair_model, "grok-4-1-fast-non-reasoning"),
      "stream" => false,
      "temperature" => 0.3
    }

    case Req.post("https://api.x.ai/v1/chat/completions",
           json: body,
           headers: [
             {"Authorization", "Bearer #{api_key}"},
             {"Content-Type", "application/json"}
           ],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        case parse_single_group_selection_response(response_body) do
          {:ok, selection} ->
            {:ok, selection}

          {:error, reason} ->
            Logger.warning(
              "[AiService] Invalid group selection response for #{group_name}: #{inspect(reason)}"
            )

            {:ok, fallback_group_selection(assets, "invalid LLM response")}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[AiService] Group selection failed with status #{status} for #{group_name}: #{inspect(body)}"
        )

        {:ok, fallback_group_selection(assets, "status #{status}")}

      {:error, exception} ->
        Logger.error(
          "[AiService] Group selection request errored for #{group_name}: #{inspect(exception)}"
        )

        {:ok, fallback_group_selection(assets, Exception.message(exception))}
    end
  end

  defp get_single_group_selection_system_prompt do
    """
    You are selecting FIRST and LAST frames for a single storyboard scene. All photos you receive
    belong to the same tag group, so both picks must come from that list.

    Requirements:
    - Respect the provided scene motion goal and camera notes.
    - Choose two distinct image IDs from the group (unless only one image is available).
    - Explain why the pair fits, referencing metadata (room type, lighting, etc.).

    Respond with a single JSON object:
    {
      "first_image_id": "uuid",
      "last_image_id": "uuid",
      "reasoning": "short explanation"
    }
    """
  end

  defp build_single_group_scene_prompt(template, group_name, assets, campaign_brief) do
    asset_catalog =
      assets
      |> Enum.map(&format_asset_entry/1)
      |> Enum.join("\n")

    """
    Campaign Brief:
    #{campaign_brief || "N/A"}

    Scene details:
    #{format_scene_requirement(template)}

    Photo group "#{group_name}" (#{length(assets)} options):
    #{asset_catalog}

    Instructions:
    - Use ONLY images from this group.
    - Select two complementary images as FIRST and LAST frame.
    - Ensure they support the motion goal (#{template.motion_goal}) and camera move (#{template.camera_movement}).
    - Provide concise reasoning referencing metadata.
    """
  end

  defp parse_single_group_selection_response(response_body) do
    content = extract_message_content(response_body)

    with {:ok, %{"first_image_id" => first, "last_image_id" => last} = obj}
         when is_binary(first) and
                is_binary(last) <-
           extract_json_object_from_content(content) do
      {:ok,
       %{
         first_image_id: first,
         last_image_id: last,
         reasoning: Map.get(obj, "reasoning", "")
       }}
    else
      _ -> {:error, :invalid_selection_payload}
    end
  end

  defp fallback_group_selection([single], reason) do
    %{
      first_image_id: single.id,
      last_image_id: single.id,
      reasoning: "Fallback (single image) due to #{reason}"
    }
  end

  defp fallback_group_selection(assets, reason) do
    first = List.first(assets)
    last = List.last(assets) || first

    %{
      first_image_id: first.id,
      last_image_id: last.id,
      reasoning: "Fallback pair chosen locally due to #{reason}"
    }
  end

  defp build_scenes_from_grouped_selection(templates, selections) do
    templates
    |> Enum.zip(selections)
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
        "asset_ids" => [selection.first_image_id, selection.last_image_id],
        "music_description" => template.music_description,
        "music_style" => template.music_style,
        "music_energy" => template.music_energy,
        "selection_reasoning" => selection.reasoning
      }
    end)
  end

  defp extract_message_content(response_body) do
    response_body
    |> Map.get("choices", [])
    |> List.first()
    |> case do
      %{"message" => %{"content" => content}} -> normalize_message_content(content)
      _ -> ""
    end
  end

  defp normalize_message_content(content) when is_binary(content), do: content

  defp normalize_message_content(content) when is_list(content) do
    content
    |> Enum.map(&content_fragment_to_string/1)
    |> Enum.join("\n")
  end

  defp normalize_message_content(%{"text" => text}), do: text
  defp normalize_message_content(%{"json" => json}) when is_map(json), do: Jason.encode!(json)
  defp normalize_message_content(%{"json" => json}) when is_binary(json), do: json
  defp normalize_message_content(%{"content" => inner}) when is_binary(inner), do: inner
  defp normalize_message_content(other) when is_binary(other), do: other
  defp normalize_message_content(other), do: Jason.encode!(other)

  defp content_fragment_to_string(%{"text" => text}), do: text
  defp content_fragment_to_string(%{"json" => json}) when is_map(json), do: Jason.encode!(json)
  defp content_fragment_to_string(%{"json" => json}) when is_binary(json), do: json
  defp content_fragment_to_string(%{"content" => inner}) when is_binary(inner), do: inner
  defp content_fragment_to_string(fragment) when is_binary(fragment), do: fragment
  defp content_fragment_to_string(fragment), do: Jason.encode!(fragment)

  defp extract_json_array_from_content(content) when is_binary(content) do
    case Regex.run(~r/\[[\s\S]*?\]/, content) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, value} when is_list(value) -> {:ok, value}
          error -> error
        end

      _ ->
        case Jason.decode(content) do
          {:ok, value} when is_list(value) -> {:ok, value}
          {:ok, %{"items" => value}} when is_list(value) -> {:ok, value}
          _ -> {:error, :no_json_array}
        end
    end
  end

  defp extract_json_object_from_content(content) when is_binary(content) do
    case Regex.run(~r/\{[\s\S]*?\}/, content) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, value} when is_map(value) -> {:ok, value}
          error -> error
        end

      _ ->
        case Jason.decode(content) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:error, :no_json_object}
        end
    end
  end

  defp extract_scene_types_from_assets(assets) do
    assets
    |> Enum.flat_map(fn asset ->
      metadata = asset.metadata || %{}

      cond do
        is_list(asset.tags) and asset.tags != [] ->
          asset.tags

        match?(%{"scene_type" => type} when is_binary(type), metadata) ->
          [metadata["scene_type"]]

        match?(%{"tags" => tags} when is_list(tags), metadata) ->
          metadata["tags"]

        match?(%{"tags" => tags} when is_binary(tags), metadata) ->
          case Jason.decode(metadata["tags"]) do
            {:ok, decoded} when is_list(decoded) -> decoded
            _ -> []
          end

        true ->
          []
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
    You are the senior curator for a luxury lodging video pipeline. Marketing already defined a
    storyboard with explicit camera moves per scene. Your job is to study dozens of crawled photos
    (each photo includes tags/metadata) and pick the best FIRST and LAST image for every scene.

    Guidelines:
    - Scenes arrive in a fixed order. Produce exactly one recommendation per scene, in the same order.
    - Each scene needs two unique photos (FIRST + LAST) that feel like a natural transition.
    - Never reuse an image across scenes unless we explicitly tell you there are not enough options.
    - Use the metadata (room_type, tags, keywords, capture_notes, etc.) plus the described motion goal
      to justify your pick.
    - Favor landscape/horizontal images, clean compositions, and matching lighting between FIRST/LAST.
    - If a scene references "requires_pairs", prioritize before/after or matching angles for that pair.

    Response contract:
    Return ONLY a JSON array (no prose) with one object per scene, e.g.
    [
      {
        "scene_type": "hook",
        "first_image_id": "uuid",
        "last_image_id": "uuid",
        "reasoning": "Short explanation referencing metadata that proves why the pair works"
      }
    ]

    The reasoning string should mention concrete cues (e.g., "both tagged master_bedroom", "sunset lighting")
    so downstream reviewers can understand the pairing.
    """
  end

  defp build_image_pair_selection_prompt(assets, campaign_brief, templates, _options) do
    asset_catalog =
      assets
      |> Enum.map(&format_asset_entry/1)
      |> Enum.join("\n")

    scene_brief =
      templates
      |> Enum.map(&format_scene_requirement/1)
      |> Enum.join("\n\n")

    """
    Campaign Brief:
    #{campaign_brief || "N/A"}

    Photo Catalog (#{length(assets)} crawled images):
    #{asset_catalog}

    Storyboard + Direction (#{length(templates)} scenes in order):
    #{scene_brief}

    Instructions:
    - Output #{length(templates)} objects in the exact scene order above (typically 7 scenes totalling ~10s).
    - Choose 2 UNIQUE images per scene (FIRST + LAST) → #{length(templates) * 2} total images.
    - Respect each scene's motion goal, camera move, and asset guidance.
    - Reference the metadata fields shown above when explaining your reasoning.
    - Prefer images tagged with the requested room/feature; skip mismatched rooms even if attractive.
    - If options are sparse, note it in reasoning but still pick the best available pair.
    - Respond with JSON only. No commentary outside the array.
    """
  end

  defp format_asset_entry(asset) do
    metadata_str =
      case asset.metadata do
        %{} = meta ->
          meta
          |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
          |> Enum.join(", ")

        _ ->
          "no metadata"
      end

    type_label =
      asset.type
      |> case do
        nil -> "unknown"
        value -> to_string(value)
      end

    """
    - id=#{asset.id}
      type=#{type_label}
      metadata={#{metadata_str}}
    """
  end

  defp format_scene_requirement(template) do
    criteria = template.asset_criteria || %{}

    """
    Scene #{template.order}: #{template.title} — #{template.subtitle}
      • Scene key: #{template.type}
      • Timecode: #{format_timecode(template.time_start)} → #{format_timecode(template.time_end)}
      • Duration: #{format_duration(template.default_duration)}
      • Motion goal: #{template.motion_goal}
      • Camera move: #{template.camera_movement}
      • Video prompt reference:
        #{template.video_prompt |> String.trim()}
      • Asset guidance:
          - Scene types: #{format_list(criteria[:scene_types])}
          - Preferred tags: #{format_list(criteria[:preferred_tags])}
          - Keywords: #{format_list(criteria[:keywords])}
          - Requires before/after pair?: #{format_boolean(criteria[:requires_pairs])}
    """
  end

  defp format_timecode(nil), do: "n/a"

  defp format_timecode(seconds) when is_number(seconds) do
    minutes = trunc(seconds / 60)
    secs = seconds - minutes * 60

    formatted_secs =
      secs
      |> :io_lib.format("~05.2f", [secs])
      |> IO.iodata_to_binary()

    "#{pad2(minutes)}:#{formatted_secs}"
  end

  defp format_duration(nil), do: "n/a"

  defp format_duration(value) when is_number(value) do
    value
    |> :io_lib.format("~.2f s", [value])
    |> IO.iodata_to_binary()
  end

  defp format_list(nil), do: "n/a"
  defp format_list([]), do: "n/a"

  defp format_list(list) when is_list(list) do
    list
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> case do
      [] -> "n/a"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_boolean(true), do: "yes"
  defp format_boolean(false), do: "no"
  defp format_boolean(_), do: "optional"

  defp pad2(int) do
    int
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
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

  defp retry_xai(fun, attempt \\ 1)

  defp retry_xai(fun, attempt) when attempt <= @max_ai_retries do
    case fun.(attempt) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        if attempt < @max_ai_retries do
          Logger.warning(
            "[AiService] AI attempt #{attempt} failed: #{inspect(reason)}. Retrying..."
          )

          retry_xai(fun, attempt + 1)
        else
          {:error, reason}
        end
    end
  end
end
