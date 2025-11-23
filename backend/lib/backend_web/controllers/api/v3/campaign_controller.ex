defmodule BackendWeb.Api.V3.CampaignController do
  @moduledoc """
  Controller for campaign management endpoints in API v3.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Campaign, Asset, Job}
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
      Logger.info("[CampaignController] Job #{job.id} created successfully with #{length(scenes)} scenes")

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

  # Private helpers

  defp campaign_json(campaign) do
    %{
      id: campaign.id,
      clientId: campaign.client_id,
      name: campaign.name,
      goal: Map.get(campaign, :goal),
      status: Map.get(campaign, :status),
      productUrl: Map.get(campaign, :product_url),
      brief: normalize_brief(campaign.brief),
      metadata: Map.get(campaign, :metadata),
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
    alias Backend.Services.AiService

    # Determine number of scenes from params
    num_scenes = Map.get(params, "num_scenes", 4)
    clip_duration = Map.get(params, "clip_duration", 4)

    # Use property_photos job type for campaigns
    case AiService.generate_scenes(assets, campaign.brief, :property_photos, %{
           num_scenes: num_scenes,
           clip_duration: clip_duration
         }) do
      {:ok, scenes} ->
        {:ok, scenes}

      {:error, reason} ->
        {:error, :scene_generation_failed, reason}
    end
  end

  defp create_job_with_scenes(campaign_id, campaign, scenes, params) do
    alias Backend.Schemas.Job

    job_params = %{
      type: :property_photos,
      status: :pending,
      storyboard: %{
        scenes: scenes,
        total_duration: calculate_total_duration(scenes)
      },
      parameters: %{
        "campaign_id" => campaign_id,
        "campaign_name" => campaign.name,
        "campaign_brief" => campaign.brief || "No brief provided",
        "asset_count" => length(Repo.all(from(a in Asset, where: a.campaign_id == ^campaign_id))),
        "style" => Map.get(params, "style", "modern"),
        "music_genre" => Map.get(params, "music_genre", "upbeat"),
        "duration_seconds" => Map.get(params, "duration_seconds", 30)
      },
      progress: %{
        percentage: 0,
        stage: "pending"
      }
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
