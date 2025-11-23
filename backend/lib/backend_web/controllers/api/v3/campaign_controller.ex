defmodule BackendWeb.Api.V3.CampaignController do
  @moduledoc """
  Controller for campaign management endpoints in API v3.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Campaign, Asset}
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
        assets = Repo.all(from a in Asset, where: a.campaign_id == ^campaign_id)

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
    case Repo.get(Campaign, campaign_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Campaign not found", code: "not_found"}})

      campaign ->
        # Get all assets for the campaign
        assets = Repo.all(from a in Asset, where: a.campaign_id == ^campaign_id)

        if length(assets) == 0 do
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: %{
              message: "Campaign has no assets",
              code: "no_assets"
            }
          })
        else
          # Create a job with the campaign's assets
          job_params =
            Map.merge(params, %{
              "campaign_id" => campaign_id,
              "asset_ids" => Enum.map(assets, & &1.id),
              "type" => params["type"] || "campaign",
              "parameters" => %{
                "campaign_name" => campaign.name,
                "campaign_brief" => campaign.brief,
                "asset_count" => length(assets),
                "style" => params["style"] || "modern",
                "music_genre" => params["music_genre"] || "upbeat",
                "duration_seconds" => params["duration_seconds"] || 30
              }
            })

          # Create the job
          case create_job_from_params(job_params) do
            {:ok, job} ->
              conn
              |> put_status(:created)
              |> json(%{
                data: %{
                  id: job.id,
                  type: job.type,
                  status: job.status,
                  campaign_id: campaign_id,
                  asset_count: length(assets),
                  parameters: job.parameters
                },
                links: %{
                  self: "/api/v3/jobs/#{job.id}",
                  approve: "/api/v3/jobs/#{job.id}/approve",
                  status: "/api/v3/jobs/#{job.id}"
                }
              })

            {:error, reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{
                error: %{
                  message: "Failed to create job",
                  code: "job_creation_failed",
                  reason: reason
                }
              })
          end
        end
    end
  end

  # Private helpers

  defp campaign_json(campaign) do
    %{
      id: campaign.id,
      name: campaign.name,
      brief: campaign.brief,
      client_id: campaign.client_id,
      inserted_at: campaign.inserted_at,
      updated_at: campaign.updated_at
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

  defp create_job_from_params(params) do
    alias Backend.Schemas.Job

    # Use property_photos as the type since Job only accepts :image_pairs or :property_photos
    job_type =
      if params["type"] in ["image_pairs", "property_photos"],
        do: String.to_existing_atom(params["type"]),
        else: :property_photos

    changeset =
      Job.changeset(%Job{}, %{
        type: job_type,
        status: :pending,
        parameters: params["parameters"] || %{},
        progress: %{percentage: 0, stage: "created"}
      })

    Repo.insert(changeset)
  end
end
