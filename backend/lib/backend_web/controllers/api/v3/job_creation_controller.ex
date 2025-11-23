defmodule BackendWeb.Api.V3.JobCreationController do
  @moduledoc """
  Controller for job creation endpoints in API v3.
  Handles creation of jobs from image pairs and property photos.
  """
  use BackendWeb, :controller
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.{Campaign, Asset, Job, SubJob}
  alias Backend.Services.AiService
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
    Logger.info("[JobCreationController] Creating job from image pairs")

    with {:ok, campaign_id} <- validate_campaign_id(params),
         {:ok, campaign} <- fetch_campaign(campaign_id),
         {:ok, assets} <- fetch_campaign_assets(campaign_id),
         :ok <- validate_assets_exist(assets),
         {:ok, scenes} <- generate_scenes(assets, campaign, :image_pairs, %{}),
         {:ok, job} <- create_job(:image_pairs, scenes, params),
         {:ok, _sub_jobs} <- create_sub_jobs(job, scenes),
         :ok <- broadcast_job_created(job.id) do
      Logger.info("[JobCreationController] Job #{job.id} created successfully")

      conn
      |> put_status(:created)
      |> json(%{
        job_id: job.id,
        status: job.status,
        type: job.type,
        scene_count: length(scenes),
        message: "Job created successfully"
      })
    else
      {:error, :missing_campaign_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "campaign_id is required"})

      {:error, :campaign_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Campaign not found"})

      {:error, :no_assets} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Campaign has no assets"})

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
         {:ok, scenes} <-
           generate_scenes(assets, campaign, :property_photos, %{property_types: property_types}),
         :ok <- validate_scene_types(scenes, property_types),
         {:ok, job} <- create_job(:property_photos, scenes, params, property_types),
         {:ok, _sub_jobs} <- create_sub_jobs(job, scenes),
         :ok <- broadcast_job_created(job.id) do
      Logger.info("[JobCreationController] Job #{job.id} created successfully")

      conn
      |> put_status(:created)
      |> json(%{
        job_id: job.id,
        status: job.status,
        type: job.type,
        scene_count: length(scenes),
        property_types: property_types,
        message: "Job created successfully"
      })
    else
      {:error, :missing_campaign_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "campaign_id is required"})

      {:error, :campaign_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Campaign not found"})

      {:error, :no_assets} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Campaign has no assets"})

      {:error, :invalid_scene_types, invalid_types} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "Scene types do not match allowed property types",
          invalid_types: invalid_types
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

  defp generate_scenes(assets, campaign, job_type, options) do
    case AiService.generate_scenes(assets, campaign.brief, job_type, options) do
      {:ok, scenes} ->
        {:ok, scenes}

      {:error, reason} ->
        {:error, :scene_generation_failed, reason}
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

  defp create_job(job_type, scenes, params, property_types \\ nil) do
    job_params = %{
      type: job_type,
      status: :pending,
      storyboard: %{
        scenes: scenes,
        total_duration: calculate_total_duration(scenes)
      },
      parameters: build_job_parameters(params, property_types),
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

  defp build_job_parameters(params, nil) do
    Map.get(params, "parameters", %{})
  end

  defp build_job_parameters(params, property_types) do
    base_params = Map.get(params, "parameters", %{})
    Map.put(base_params, "property_types", property_types)
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

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
