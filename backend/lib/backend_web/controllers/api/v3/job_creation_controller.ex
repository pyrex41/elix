defmodule BackendWeb.Api.V3.JobCreationController do
  @moduledoc """
  Controller for job creation endpoints in API v3.
  Handles creation of jobs from image pairs and property photos.
  """
  use BackendWeb, :controller
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.{Campaign, Asset, Job, SubJob}
  alias Backend.Services.{AiService, CostEstimator, VideoMetadata}
  alias BackendWeb.ApiSchemas.{JobCreationRequest, JobCreationResponse}
  alias OpenApiSpex.Operation
  import OpenApiSpex.Operation, only: [request_body: 4, response: 3]
  import Ecto.Query

  @pubsub_name Backend.PubSub
  @job_created_topic "jobs:created"

  @doc """
  POST /api/v3/jobs/from-image-pairs

  Creates a job from image pairs using AI-generated scene descriptions.

  ## Parameters
    - campaign_id: UUID of the campaign (required)
    - parameters: Additional job parameters (optional)

  ## Response
    - 201: Job created successfully with job_id
    - 400: Bad request (missing required parameters)
    - 404: Campaign not found
    - 422: Validation error
    - 500: Server error (AI generation failed, etc.)
  """
  def from_image_pairs(conn, params) do
    params = normalize_job_params(params)
    Logger.info("[JobCreationController] Creating job from image pairs")

    with {:ok, campaign_id} <- validate_campaign_id(params),
         {:ok, campaign} <- fetch_campaign(campaign_id),
         {:ok, assets} <- fetch_campaign_assets(campaign_id, type: :image),
         :ok <- validate_assets_exist(assets),
         :ok <- ensure_min_assets(assets, 2),
         scene_options <- build_scene_options(params),
         {:ok, scenes} <- generate_scenes(assets, campaign, :image_pairs, scene_options),
         {:ok, job} <- create_job(:image_pairs, scenes, params, campaign),
         {:ok, _sub_jobs} <- create_sub_jobs(job, scenes),
         :ok <- broadcast_job_created(job.id) do
      Logger.info("[JobCreationController] Job #{job.id} created successfully")

      conn
      |> put_status(:created)
      |> json(
        build_job_response(job, scenes, %{
          "campaign_id" => campaign_id,
          "client_id" => params["client_id"],
          "clip_duration" => params["clip_duration"],
          "num_pairs" => params["num_pairs"],
          "total_assets" => length(assets)
        })
      )
    else
      {:error, :missing_campaign_id} ->
        Logger.warning("[JobCreationController] 400 Bad Request: campaign_id is required. Params: #{inspect(Map.drop(params, ["parameters"]))}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "campaign_id is required"})

      {:error, :campaign_not_found} ->
        Logger.warning("[JobCreationController] 404 Not Found: Campaign #{params["campaign_id"]} not found")
        conn
        |> put_status(:not_found)
        |> json(%{error: "Campaign not found", campaign_id: params["campaign_id"]})

      {:error, :no_assets} ->
        Logger.warning("[JobCreationController] 400 Bad Request: Campaign #{params["campaign_id"]} has no image assets")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Campaign has no image assets", campaign_id: params["campaign_id"]})

      {:error, {:not_enough_assets, required, actual}} ->
        Logger.warning("[JobCreationController] 400 Bad Request: Campaign #{params["campaign_id"]} has #{actual} image assets, need #{required}")
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "Need at least #{required} image assets to start the pipeline, found #{actual}",
          campaign_id: params["campaign_id"],
          image_asset_count: actual,
          required: required
        })

      {:error, :scene_generation_failed, reason} ->
        Logger.error("[JobCreationController] Scene generation failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to generate scenes", details: reason})

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Validation failed",
          details: format_changeset_errors(changeset)
        })

      {:error, reason} ->
        Logger.error("[JobCreationController] Job creation failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to create job", details: to_string(reason)})
    end
  end

  @doc """
  POST /api/v3/jobs/from-property-photos

  Creates a job from property photos using AI-generated scene descriptions.
  Validates that scene types match allowed property types.

  ## Parameters
    - campaign_id: UUID of the campaign (required)
    - property_types: List of allowed property types (optional, defaults to common types)
    - parameters: Additional job parameters (optional)

  ## Response
    - 201: Job created successfully with job_id
    - 400: Bad request (missing required parameters, invalid scene types)
    - 404: Campaign not found
    - 422: Validation error
    - 500: Server error (AI generation failed, etc.)
  """
  def from_property_photos(conn, params) do
    Logger.info("[JobCreationController] Creating job from property photos")

    with {:ok, campaign_id} <- validate_campaign_id(params),
         {:ok, property_types} <- parse_property_types(params),
         {:ok, campaign} <- fetch_campaign(campaign_id),
         {:ok, assets} <- fetch_campaign_assets(campaign_id),
         :ok <- validate_assets_exist(assets),
         scene_options <- build_scene_options(params) |> Map.put(:property_types, property_types),
         {:ok, scenes} <-
           generate_scenes(assets, campaign, :property_photos, scene_options),
         :ok <- validate_scene_types(scenes, property_types),
         {:ok, job} <- create_job(:property_photos, scenes, params, campaign, property_types),
         {:ok, _sub_jobs} <- create_sub_jobs(job, scenes),
         :ok <- broadcast_job_created(job.id) do
      Logger.info("[JobCreationController] Job #{job.id} created successfully")

      conn
      |> put_status(:created)
      |> json(
        build_job_response(job, scenes, %{
          "property_types" => property_types
        })
      )
    else
      {:error, :missing_campaign_id} ->
        Logger.warning("[JobCreationController] 400 Bad Request: campaign_id is required (property_photos)")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "campaign_id is required"})

      {:error, :campaign_not_found} ->
        Logger.warning("[JobCreationController] 404 Not Found: Campaign #{params["campaign_id"]} not found (property_photos)")
        conn
        |> put_status(:not_found)
        |> json(%{error: "Campaign not found", campaign_id: params["campaign_id"]})

      {:error, :no_assets} ->
        Logger.warning("[JobCreationController] 400 Bad Request: Campaign #{params["campaign_id"]} has no assets (property_photos)")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Campaign has no assets", campaign_id: params["campaign_id"]})

      {:error, :invalid_scene_types, invalid_types} ->
        Logger.warning("[JobCreationController] 400 Bad Request: Invalid scene types #{inspect(invalid_types)} for campaign #{params["campaign_id"]}")
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "Scene types do not match allowed property types",
          invalid_types: invalid_types,
          campaign_id: params["campaign_id"]
        })

      {:error, :scene_generation_failed, reason} ->
        Logger.error("[JobCreationController] Scene generation failed for campaign #{params["campaign_id"]}: #{inspect(reason)}")
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to generate scenes", details: reason, campaign_id: params["campaign_id"]})

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        Logger.warning("[JobCreationController] 422 Validation failed: #{inspect(format_changeset_errors(changeset))}")
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Validation failed",
          details: format_changeset_errors(changeset)
        })

      {:error, reason} ->
        Logger.error("[JobCreationController] Job creation failed for campaign #{params["campaign_id"]}: #{inspect(reason)}")
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to create job", details: to_string(reason)})
    end
  end

  @doc false
  @spec open_api_operation(atom) :: Operation.t()
  def open_api_operation(action) do
    apply(__MODULE__, :"#{action}_operation", [])
  end

  def from_image_pairs_operation do
    %Operation{
      tags: ["jobs"],
      summary: "Create job from image pairs",
      description: "Creates a job driven by paired image templates for a campaign.",
      operationId: "JobCreationController.from_image_pairs",
      requestBody:
        request_body("Job creation payload", "application/json", JobCreationRequest,
          required: true
        ),
      responses: %{
        201 => response("Job created", "application/json", JobCreationResponse)
      }
    }
  end

  def from_property_photos_operation do
    %Operation{
      tags: ["jobs"],
      summary: "Create job from property photos",
      description: "Creates a job optimised for property photo storyboards.",
      operationId: "JobCreationController.from_property_photos",
      requestBody:
        request_body("Job creation payload", "application/json", JobCreationRequest,
          required: true
        ),
      responses: %{
        201 => response("Job created", "application/json", JobCreationResponse)
      }
    }
  end

  # Private helper functions

  defp validate_campaign_id(%{"campaign_id" => campaign_id}) when is_binary(campaign_id) do
    {:ok, campaign_id}
  end

  defp validate_campaign_id(_params) do
    {:error, :missing_campaign_id}
  end

  defp parse_property_types(%{"property_types" => types}) when is_list(types) do
    {:ok, types}
  end

  defp parse_property_types(_params) do
    # Default property types
    {:ok, ["exterior", "interior", "kitchen", "bedroom", "bathroom", "living_room"]}
  end

  defp fetch_campaign(campaign_id) do
    case Repo.get(Campaign, campaign_id) do
      nil -> {:error, :campaign_not_found}
      campaign -> {:ok, campaign}
    end
  end

  defp fetch_campaign_assets(campaign_id, opts \\ []) do
    type_filter = Keyword.get(opts, :type)

    assets =
      Asset
      |> where([a], a.campaign_id == ^campaign_id)
      |> maybe_filter_asset_type(type_filter)
      |> order_by([a], asc: a.inserted_at)
      |> Repo.all()

    {:ok, assets}
  end

  defp maybe_filter_asset_type(query, nil), do: query

  defp maybe_filter_asset_type(query, type) when type in [:image, :video, :audio] do
    where(query, [a], a.type == ^type)
  end

  defp validate_assets_exist([]) do
    {:error, :no_assets}
  end

  defp validate_assets_exist(_assets) do
    :ok
  end

  defp generate_scenes(assets, campaign, job_type, options) do
    case AiService.generate_scenes(assets, campaign.brief, job_type, options) do
      {:ok, scenes} ->
        # Assign asset_ids to scenes if not already present
        scenes_with_assets = assign_assets_to_scenes(scenes, assets)
        {:ok, scenes_with_assets}

      {:error, reason} ->
        {:error, :scene_generation_failed, reason}
    end
  end

  # Assigns assets to scenes based on scene_type matching
  # This ensures each scene has asset_ids for rendering
  defp assign_assets_to_scenes(scenes, assets) do
    grouped_assets = group_assets_for_scenes(assets)

    scenes
    |> Enum.with_index()
    |> Enum.map(fn {scene, index} ->
      # Skip if scene already has asset_ids
      if has_asset_ids?(scene) do
        scene
      else
        scene_type = scene["scene_type"] || scene[:scene_type] || "general"
        matching_assets = find_matching_assets(scene_type, grouped_assets, assets, index)

        case matching_assets do
          [first | rest] ->
            last = List.last(rest) || first
            Map.put(scene, "asset_ids", [first.id, last.id])

          [] ->
            # Fallback: use assets at scene index position
            fallback_assets = get_fallback_assets(assets, index)
            Map.put(scene, "asset_ids", Enum.map(fallback_assets, & &1.id))
        end
      end
    end)
  end

  defp has_asset_ids?(scene) do
    asset_ids = scene["asset_ids"] || scene[:asset_ids]
    is_list(asset_ids) and length(asset_ids) > 0
  end

  # Groups assets by their category/tag for scene matching
  defp group_assets_for_scenes(assets) do
    assets
    |> Enum.group_by(fn asset ->
      cond do
        is_list(asset.tags) and asset.tags != [] ->
          asset.tags |> List.first() |> normalize_asset_category()

        is_binary(asset.name) and asset.name != "" ->
          normalize_asset_category(asset.name)

        true ->
          "general"
      end
    end)
  end

  # Normalizes category names for matching
  defp normalize_asset_category(nil), do: "general"

  defp normalize_asset_category(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[_\s]+\d+$/, "")  # Remove trailing numbers
    |> String.replace(~r/[_\s]+/, "_")
    |> String.trim()
  end

  # Finds assets matching the scene type
  defp find_matching_assets(scene_type, grouped_assets, all_assets, scene_index) do
    normalized_type = normalize_asset_category(scene_type)

    # Try exact match first
    exact_match = Map.get(grouped_assets, normalized_type, [])

    if length(exact_match) >= 2 do
      Enum.take(exact_match, 2)
    else
      # Try partial match
      partial_matches =
        grouped_assets
        |> Enum.filter(fn {category, _} ->
          String.contains?(category, normalized_type) or
            String.contains?(normalized_type, category)
        end)
        |> Enum.flat_map(fn {_, assets} -> assets end)

      if length(partial_matches) >= 2 do
        Enum.take(partial_matches, 2)
      else
        # Fallback to index-based selection
        get_fallback_assets(all_assets, scene_index)
      end
    end
  end

  # Gets fallback assets based on scene index
  defp get_fallback_assets(assets, index) do
    asset_count = length(assets)

    if asset_count == 0 do
      []
    else
      # Use modulo to cycle through assets if we have more scenes than assets
      first_idx = rem(index * 2, asset_count)
      second_idx = rem(index * 2 + 1, asset_count)

      first = Enum.at(assets, first_idx)
      second = Enum.at(assets, second_idx) || first

      [first, second] |> Enum.reject(&is_nil/1)
    end
  end

  defp validate_scene_types(scenes, allowed_types) do
    # Extract all scene types from generated scenes
    scene_types =
      Enum.map(scenes, fn scene ->
        Map.get(scene, "scene_type")
      end)

    # Find any scene types that are not in allowed list
    invalid_types =
      Enum.reject(scene_types, fn scene_type ->
        scene_type in allowed_types
      end)

    if Enum.empty?(invalid_types) do
      :ok
    else
      {:error, :invalid_scene_types, invalid_types}
    end
  end

  defp create_job(job_type, scenes, params, campaign, property_types \\ nil) do
    model = preferred_video_model(params)

    estimated_cost =
      CostEstimator.estimate_job_cost(
        scenes,
        default_model: model,
        default_duration: params["clip_duration"]
      )

    sequence = VideoMetadata.next_video_sequence(campaign.id)
    video_name = VideoMetadata.build_video_name(campaign.name, sequence)

    parameters =
      params
      |> build_job_parameters(property_types)
      |> Map.put_new("campaign_id", campaign.id)
      |> Map.put_new("campaign_name", campaign.name)
      |> Map.put_new("video_model", model)
      |> Map.put_new("cost_currency", "USD")
      |> Map.put_new("estimated_cost", estimated_cost)
      |> Map.put_new("video_name", video_name)

    cost_currency = Map.get(parameters, "cost_currency", "USD")

    job_params = %{
      type: job_type,
      status: :pending,
      storyboard: %{
        scenes: scenes,
        total_duration: calculate_total_duration(scenes)
      },
      parameters: parameters,
      progress: %{
        percentage: 0,
        stage: "storyboard_ready",
        costs: %{
          "estimated" => estimated_cost,
          "currency" => cost_currency
        }
      },
      video_name: video_name,
      estimated_cost: estimated_cost
    }

    %Job{}
    |> Job.changeset(job_params)
    |> Repo.insert()
  end

  defp calculate_total_duration(scenes) do
    Enum.reduce(scenes, 0.0, fn scene, acc ->
      duration =
        case Map.get(scene, "duration") do
          value when is_number(value) ->
            value * 1.0

          value when is_binary(value) ->
            case Float.parse(value) do
              {float_val, _} -> float_val
              :error -> 0.0
            end

          _ ->
            0.0
        end

      acc + duration
    end)
  end

  defp build_job_parameters(params, property_types) do
    base_params =
      params
      |> Map.get("parameters", %{})
      |> case do
        nil -> %{}
        value -> value
      end

    enriched =
      base_params
      |> put_if_present("campaign_id", params["campaign_id"])
      |> put_if_present("client_id", params["client_id"])
      |> put_if_present("clip_duration", params["clip_duration"])
      |> put_if_present("num_pairs", params["num_pairs"])

    case property_types do
      nil -> enriched
      types -> Map.put(enriched, "property_types", types)
    end
  end

  defp create_sub_jobs(job, scenes) do
    # Create a sub_job for each scene
    sub_jobs =
      Enum.map(scenes, fn _scene ->
        sub_job_params = %{
          job_id: job.id,
          status: :pending
        }

        %SubJob{}
        |> SubJob.changeset(sub_job_params)
        |> Repo.insert!()
      end)

    {:ok, sub_jobs}
  end

  defp broadcast_job_created(job_id) do
    Phoenix.PubSub.broadcast(
      @pubsub_name,
      @job_created_topic,
      {:job_created, job_id}
    )

    :ok
  end

  defp normalize_job_params(%{} = params) do
    params =
      params
      |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
      |> Enum.into(%{})

    clip_duration = params["clip_duration"] || params["clipDuration"] || 5.0
    num_pairs = params["num_pairs"] || params["numPairs"] || 10

    params
    |> Map.put_new("campaign_id", params["campaign_id"] || params["campaignId"])
    |> Map.put_new("client_id", params["client_id"] || params["clientId"])
    |> Map.put("clip_duration", parse_float_param(clip_duration, 5.0))
    |> Map.put("num_pairs", parse_integer_param(num_pairs, 10))
  end

  defp normalize_job_params(params), do: params

  # Build options map for scene generation from request params
  defp build_scene_options(params) do
    clip_duration = params["clip_duration"] || 5.0
    num_pairs = params["num_pairs"] || 10

    Logger.info(
      "[JobCreationController] Building scene options: clip_duration=#{clip_duration}, num_pairs=#{num_pairs}"
    )

    %{
      clip_duration: clip_duration,
      num_scenes: num_pairs
    }
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp parse_float_param(value, _default) when is_float(value), do: value
  defp parse_float_param(value, _default) when is_integer(value), do: value * 1.0

  defp parse_float_param(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> default
    end
  end

  defp parse_float_param(_, default), do: default

  defp parse_integer_param(value, _default) when is_integer(value), do: value

  defp parse_integer_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_integer_param(_, default), do: default

  defp ensure_min_assets(assets, required) do
    actual = length(assets)

    if actual >= required do
      :ok
    else
      {:error, {:not_enough_assets, required, actual}}
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp build_job_response(job, scenes, extra_fields) do
    parameters = job.parameters || %{}
    cost_summary = job_cost_summary(job, parameters)

    base = %{
      "job_id" => job.id,
      "status" => Atom.to_string(job.status),
      "type" => Atom.to_string(job.type),
      "scene_count" => length(scenes),
      "message" => "Job created successfully",
      "video_name" => job.video_name,
      "duration" =>
        get_in(job.storyboard || %{}, ["total_duration"]) ||
          get_in(job.storyboard || %{}, [:total_duration]),
      "estimated_cost" => job.estimated_cost,
      "costs" => cost_summary,
      "storyboard_ready" => true,
      "storyboard" => %{
        "scenes" => scenes,
        "total_duration" =>
          get_in(job.storyboard || %{}, ["total_duration"]) ||
            get_in(job.storyboard || %{}, [:total_duration])
      }
    }

    extra_fields
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
    |> Map.merge(base)
  end

  defp job_cost_summary(job, parameters) do
    progress = job.progress || %{}

    summary =
      Map.get(progress, "costs") ||
        Map.get(progress, :costs)

    cond do
      is_map(summary) and summary != %{} ->
        summary

      true ->
        estimated = job.estimated_cost || fetch_param(parameters, "estimated_cost")
        currency = fetch_param(parameters, "cost_currency") || "USD"

        %{
          "estimated" => estimated,
          "currency" => currency
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.into(%{})
    end
  end

  defp fetch_param(map, key) when is_map(map) do
    map[key] ||
      case safe_to_existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(map, atom_key)
      end
  end

  defp fetch_param(_, _), do: nil

  defp safe_to_existing_atom(nil), do: nil

  defp safe_to_existing_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp preferred_video_model(params) do
    params["video_model"] ||
      params["model"] ||
      get_in(params, ["parameters", "video_model"]) ||
      Application.get_env(:backend, :video_generation_model, "veo3")
  end
end
