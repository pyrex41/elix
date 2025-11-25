defmodule BackendWeb.Api.V3.CampaignController do
  @moduledoc """
  Controller for campaign management endpoints in API v3.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Campaign, Asset, Job}
  alias Backend.Services.{AiService, CostEstimator, VideoMetadata}

  alias BackendWeb.ApiSchemas.{
    CampaignRequest,
    CampaignResponse,
    CampaignListResponse,
    CampaignStatsResponse,
    CampaignJobRequest,
    CampaignJobResponse,
    AssetListResponse,
    ErrorResponse
  }

  alias OpenApiSpex.{Operation, Schema}
  import OpenApiSpex.Operation, only: [parameter: 5, request_body: 4, response: 3]
  import Ecto.Query
  require Logger

  def index(conn, params) do
    query = Campaign

    query =
      if client_id = params["client_id"] do
        where(query, [c], c.client_id == ^client_id)
      else
        query
      end

    campaigns = Repo.all(query)

    json(conn, %{
      data: Enum.map(campaigns, &campaign_json/1),
      meta: %{
        total: length(campaigns)
      }
    })
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Campaign, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      campaign ->
        json(conn, %{data: campaign_json(campaign)})
    end
  end

  def create(conn, params) do
    changeset = Campaign.changeset(%Campaign{}, params)

    case Repo.insert(changeset) do
      {:ok, campaign} ->
        conn
        |> put_status(:created)
        |> json(%{data: campaign_json(campaign)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            message: "Validation failed",
            code: "validation_failed",
            details: format_changeset_errors(changeset)
          }
        })
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Repo.get(Campaign, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      campaign ->
        changeset = Campaign.changeset(campaign, params)

        case Repo.update(changeset) do
          {:ok, updated_campaign} ->
            json(conn, %{data: campaign_json(updated_campaign)})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: %{
                message: "Validation failed",
                code: "validation_failed",
                details: format_changeset_errors(changeset)
              }
            })
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Campaign, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      campaign ->
        Repo.delete!(campaign)
        send_resp(conn, :no_content, "")
    end
  end

  def get_assets(conn, %{"id" => campaign_id}) do
    case Repo.get(Campaign, campaign_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      _campaign ->
        assets = Repo.all(from(a in Asset, where: a.campaign_id == ^campaign_id))

        json(conn, %{
          data: Enum.map(assets, &asset_json/1),
          meta: %{
            campaign_id: campaign_id,
            total: length(assets)
          }
        })
    end
  end

  def create_job(conn, %{"id" => campaign_id} = params) do
    Logger.info("[CampaignController] Creating job for campaign #{campaign_id}")

    with {:ok, campaign} <- fetch_campaign(campaign_id),
         {:ok, assets} <- fetch_campaign_assets(campaign_id),
         :ok <- validate_assets_exist(assets),
         {:ok, scenes} <- generate_scenes_for_campaign(assets, campaign, params),
         {:ok, job} <- create_job_with_scenes(campaign_id, campaign, scenes, params),
         {:ok, _sub_jobs} <- create_sub_jobs_for_job(job, scenes) do
      Logger.info(
        "[CampaignController] Job #{job.id} created successfully with #{length(scenes)} scenes"
      )

      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          id: job.id,
          type: job.type,
          status: job.status,
          campaign_id: campaign_id,
          asset_count: length(assets),
          scene_count: length(scenes),
          parameters: job.parameters
        },
        links: %{
          self: "/api/v3/jobs/#{job.id}",
          approve: "/api/v3/jobs/#{job.id}/approve",
          status: "/api/v3/jobs/#{job.id}"
        }
      })
    else
      {:error, :campaign_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      {:error, :no_assets} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{message: "Campaign has no assets", code: "no_assets"}})

      {:error, :scene_generation_failed, reason} ->
        Logger.error("[CampaignController] Scene generation failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            message: "Failed to generate scenes",
            code: "scene_generation_failed",
            details: inspect(reason)
          }
        })

      {:error, reason} ->
        Logger.error("[CampaignController] Job creation failed: #{inspect(reason)}")

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            message: "Failed to create job",
            code: "job_creation_failed",
            reason: inspect(reason)
          }
        })
    end
  end

  def stats(conn, %{"id" => campaign_id}) do
    case Repo.get(Campaign, campaign_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      _campaign ->
        json(conn, %{data: campaign_stats(campaign_id)})
    end
  end

  @doc false
  @spec open_api_operation(atom) :: Operation.t() | nil
  def open_api_operation(action) do
    fun = :"#{action}_operation"

    if function_exported?(__MODULE__, fun, 0) do
      apply(__MODULE__, fun, [])
    else
      nil
    end
  end

  def index_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "List campaigns",
      operationId: "CampaignController.index",
      parameters: [
        parameter(:client_id, :query, :string, "Filter by client ID",
          required: false,
          example: "b6f9fdd3-2c88-4aa4-8857-8a1da43e3bb8"
        )
      ],
      responses: %{
        200 => response("Campaigns", "application/json", CampaignListResponse)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "Get campaign",
      operationId: "CampaignController.show",
      parameters: [
        parameter(:id, :path, :string, "Campaign ID",
          example: "d2d06a3d-2c02-4db0-b3ad-8f6c9bcc6fd6"
        )
      ],
      responses: %{
        200 => response("Campaign", "application/json", CampaignResponse),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  def create_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "Create campaign",
      operationId: "CampaignController.create",
      requestBody:
        request_body("Campaign payload", "application/json", CampaignRequest, required: true),
      responses: %{
        201 => response("Created", "application/json", CampaignResponse),
        422 => response("Validation error", "application/json", ErrorResponse)
      }
    }
  end

  def update_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "Update campaign",
      operationId: "CampaignController.update",
      parameters: [
        parameter(:id, :path, :string, "Campaign ID",
          example: "d2d06a3d-2c02-4db0-b3ad-8f6c9bcc6fd6"
        )
      ],
      requestBody:
        request_body("Campaign payload", "application/json", CampaignRequest, required: true),
      responses: %{
        200 => response("Updated", "application/json", CampaignResponse),
        404 => response("Not found", "application/json", ErrorResponse),
        422 => response("Validation error", "application/json", ErrorResponse)
      }
    }
  end

  def delete_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "Delete campaign",
      operationId: "CampaignController.delete",
      parameters: [
        parameter(:id, :path, :string, "Campaign ID",
          example: "d2d06a3d-2c02-4db0-b3ad-8f6c9bcc6fd6"
        )
      ],
      responses: %{
        204 => response("Deleted", "application/json", %Schema{type: :null}),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  def get_assets_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "List campaign assets",
      operationId: "CampaignController.get_assets",
      parameters: [
        parameter(:id, :path, :string, "Campaign ID",
          example: "d2d06a3d-2c02-4db0-b3ad-8f6c9bcc6fd6"
        )
      ],
      responses: %{
        200 => response("Assets", "application/json", AssetListResponse),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  def create_job_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "Create job from campaign",
      description: "Generates a job using all assets in the campaign.",
      operationId: "CampaignController.create_job",
      parameters: [
        parameter(:id, :path, :string, "Campaign ID",
          example: "d2d06a3d-2c02-4db0-b3ad-8f6c9bcc6fd6"
        )
      ],
      requestBody:
        request_body("Job options", "application/json", CampaignJobRequest, required: false),
      responses: %{
        201 => response("Job created", "application/json", CampaignJobResponse),
        404 => response("Not found", "application/json", ErrorResponse),
        422 => response("Validation error", "application/json", ErrorResponse)
      }
    }
  end

  def stats_operation do
    %Operation{
      tags: ["campaigns"],
      summary: "Campaign stats",
      operationId: "CampaignController.stats",
      parameters: [
        parameter(:id, :path, :string, "Campaign ID",
          example: "d2d06a3d-2c02-4db0-b3ad-8f6c9bcc6fd6"
        )
      ],
      responses: %{
        200 => response("Stats", "application/json", CampaignStatsResponse),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  # Private helpers

  defp campaign_json(campaign) do
    %{
      id: campaign.id,
      clientId: campaign.client_id,
      name: campaign.name,
      goal: campaign.goal,
      status: campaign.status,
      productUrl: campaign.product_url,
      brief: normalize_brief(campaign.brief),
      metadata: campaign.metadata,
      createdAt: format_timestamp(campaign.inserted_at),
      updatedAt: format_timestamp(campaign.updated_at)
    }
  end

  defp asset_json(asset) do
    %{
      id: asset.id,
      type: asset.type,
      campaign_id: asset.campaign_id,
      source_url: asset.source_url,
      metadata: asset.metadata || %{},
      has_blob_data: asset.blob_data != nil,
      inserted_at: asset.inserted_at,
      updated_at: asset.updated_at
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp normalize_brief(nil), do: nil
  defp normalize_brief(%{} = brief), do: brief

  defp normalize_brief(brief) when is_binary(brief) do
    case Jason.decode(brief) do
      {:ok, decoded} -> decoded
      _ -> brief
    end
  end

  defp normalize_brief(brief), do: brief

  defp format_timestamp(nil), do: nil

  defp format_timestamp(%NaiveDateTime{} = datetime) do
    NaiveDateTime.to_iso8601(datetime)
  end

  defp format_timestamp(%DateTime{} = datetime) do
    DateTime.to_iso8601(datetime)
  end

  defp format_timestamp(value) when is_binary(value), do: value
  defp format_timestamp(_), do: nil

  defp campaign_stats(campaign_id) do
    job_query =
      from(j in Job,
        where: fragment("json_extract(?, '$.campaign_id') = ?", j.parameters, ^campaign_id)
      )

    video_count = Repo.aggregate(job_query, :count, :id)

    %{
      videoCount: video_count,
      totalSpend: 0.0,
      avgCost: 0.0
    }
  end

  # Helper functions for job creation with scene generation

  defp fetch_campaign(campaign_id) do
    case Repo.get(Campaign, campaign_id) do
      nil -> {:error, :campaign_not_found}
      campaign -> {:ok, campaign}
    end
  end

  defp fetch_campaign_assets(campaign_id) do
    assets =
      Asset
      |> where([a], a.campaign_id == ^campaign_id)
      |> order_by([a], asc: a.inserted_at)
      |> Repo.all()

    {:ok, assets}
  end

  defp validate_assets_exist([]) do
    {:error, :no_assets}
  end

  defp validate_assets_exist(_assets) do
    :ok
  end

  defp generate_scenes_for_campaign(assets, campaign, params) do
    # Determine number of scenes from params
    num_scenes = Map.get(params, "num_scenes", 4)
    clip_duration = Map.get(params, "clip_duration", 4)

    # Use property_photos job type for campaigns
    case AiService.generate_scenes(assets, campaign.brief, :property_photos, %{
           num_scenes: num_scenes,
           clip_duration: clip_duration
         }) do
      {:ok, scenes} ->
        # Assign assets to scenes based on scene_type
        scenes_with_assets = assign_assets_to_scenes(scenes, assets)
        {:ok, scenes_with_assets}

      {:error, reason} ->
        {:error, :scene_generation_failed, reason}
    end
  end

  # Assigns assets to scenes based on scene_type matching
  defp assign_assets_to_scenes(scenes, assets) do
    # Group assets by category/tag for matching
    grouped_assets = group_assets_for_scenes(assets)

    scenes
    |> Enum.with_index()
    |> Enum.map(fn {scene, index} ->
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
    end)
  end

  # Groups assets by their category/tag for scene matching
  defp group_assets_for_scenes(assets) do
    assets
    |> Enum.group_by(fn asset ->
      cond do
        is_list(asset.tags) and asset.tags != [] ->
          asset.tags |> List.first() |> normalize_category()

        is_binary(asset.name) and asset.name != "" ->
          normalize_category(asset.name)

        true ->
          "general"
      end
    end)
  end

  # Normalizes category names for matching
  defp normalize_category(nil), do: "general"

  defp normalize_category(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[_\s]+\d+$/, "")  # Remove trailing numbers
    |> String.replace(~r/[_\s]+/, "_")
    |> String.trim()
  end

  # Finds assets matching the scene type
  defp find_matching_assets(scene_type, grouped_assets, all_assets, scene_index) do
    normalized_type = normalize_category(scene_type)

    # Try exact match first
    exact_match = Map.get(grouped_assets, normalized_type, [])

    if length(exact_match) >= 2 do
      Enum.take(exact_match, 2)
    else
      # Try partial match
      partial_matches =
        grouped_assets
        |> Enum.filter(fn {category, _assets} ->
          String.contains?(category, normalized_type) or
            String.contains?(normalized_type, category)
        end)
        |> Enum.flat_map(fn {_category, assets} -> assets end)

      if length(partial_matches) >= 2 do
        Enum.take(partial_matches, 2)
      else
        # Use assets distributed by scene index
        get_fallback_assets(all_assets, scene_index)
      end
    end
  end

  # Gets fallback assets distributed across scenes
  defp get_fallback_assets(assets, scene_index) do
    asset_count = length(assets)

    if asset_count < 2 do
      assets
    else
      # Distribute assets evenly across scenes
      chunk_size = max(div(asset_count, 4), 2)
      start_index = rem(scene_index * chunk_size, asset_count)

      assets
      |> Enum.slice(start_index, 2)
      |> case do
        [] -> Enum.take(assets, 2)
        [single] -> [single, List.last(assets)]
        pair -> pair
      end
    end
  end

  defp create_job_with_scenes(campaign_id, campaign, scenes, params) do
    alias Backend.Schemas.Job

    default_model = Application.get_env(:backend, :video_generation_model, "veo3")

    estimated_cost =
      CostEstimator.estimate_job_cost(
        scenes,
        default_model: default_model
      )

    sequence = VideoMetadata.next_video_sequence(campaign_id)
    video_name = VideoMetadata.build_video_name(campaign.name, sequence)

    parameter_payload = %{
      "campaign_id" => campaign_id,
      "campaign_name" => campaign.name,
      "campaign_brief" => campaign.brief || "No brief provided",
      "asset_count" => length(Repo.all(from(a in Asset, where: a.campaign_id == ^campaign_id))),
      "style" => Map.get(params, "style", "modern"),
      "music_genre" => Map.get(params, "music_genre", "upbeat"),
      "duration_seconds" => Map.get(params, "duration_seconds", 30),
      "video_model" => default_model,
      "estimated_cost" => estimated_cost,
      "cost_currency" => "USD",
      "video_name" => video_name
    }

    job_params = %{
      type: :property_photos,
      status: :pending,
      storyboard: %{
        scenes: scenes,
        total_duration: calculate_total_duration(scenes)
      },
      parameters: parameter_payload,
      progress: %{
        percentage: 0,
        stage: "storyboard_ready",
        costs: %{
          "estimated" => estimated_cost,
          "currency" => "USD"
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
    Enum.reduce(scenes, 0, fn scene, acc ->
      duration = Map.get(scene, "duration", 0)
      acc + duration
    end)
  end

  defp create_sub_jobs_for_job(job, scenes) do
    alias Backend.Schemas.SubJob

    # Create a sub_job for each scene
    sub_jobs =
      Enum.with_index(scenes, fn scene, index ->
        sub_job_params = %{
          job_id: job.id,
          status: :pending,
          scene_index: index,
          prompt: Map.get(scene, "prompt", ""),
          metadata: %{
            scene_type: Map.get(scene, "scene_type"),
            duration: Map.get(scene, "duration", 4)
          }
        }

        %SubJob{}
        |> SubJob.changeset(sub_job_params)
        |> Repo.insert!()
      end)

    {:ok, sub_jobs}
  end
end
