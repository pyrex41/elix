defmodule Backend.Services.AiService do
  @moduledoc """
  Service module for interacting with AI APIs (xAI/Grok).
  Handles scene generation from campaign assets.
  """
  require Logger

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
        call_xai_api(assets, campaign_brief, job_type, options, api_key)
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
      "model" => "grok-beta",
      "stream" => false,
      "temperature" => 0.7
    }

    case Req.post(url, json: body, headers: headers) do
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
end
