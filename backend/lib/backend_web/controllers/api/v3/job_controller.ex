defmodule BackendWeb.Api.V3.JobController do
  @moduledoc """
  Controller for job management endpoints in API v3.
  """
  use BackendWeb, :controller
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Workflow.Coordinator
  alias BackendWeb.ApiSchemas.{JobApprovalResponse, JobShowResponse}
  alias OpenApiSpex.Operation
  import OpenApiSpex.Operation, only: [parameter: 5, response: 3]
  import Ecto.Query

  @default_limit 25
  @max_limit 100

  @doc """
  POST /api/v3/jobs/:id/approve

  Approves a job and triggers processing workflow.

  ## Parameters
    - id: The job ID to approve

  ## Response
    - 200: Job approved successfully
    - 404: Job not found
    - 422: Job cannot be approved (invalid state)
  """
  def approve(conn, params) do
    job_id = normalize_id(params)
    Logger.info("[JobController] Approving job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        job_id_str = to_string(job_id)

        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: job_id_str})

      job ->
        # Validate that job is in pending state
        case job.status do
          :pending ->
            # Send approval message to Coordinator
            Coordinator.approve_job(job.id)

            conn
            |> put_status(:ok)
            |> json(%{
              message: "Job approved successfully",
              job_id: job.id,
              status: "approved"
            })

          status ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: "Job cannot be approved",
              job_id: job.id,
              current_status: status,
              reason: "Job must be in pending state to be approved"
            })
        end
    end
  end

  @doc """
  GET /api/v3/jobs/:id

  Returns job status and progress.

  ## Parameters
    - id: The job ID

  ## Response
    - 200: Job details with status and progress
    - 404: Job not found
  """
  def show(conn, params) do
    job_id = normalize_id(params)

    case Repo.get(Job, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found", job_id: to_string(job_id)})

      job ->
        # Calculate progress percentage from progress field
        progress_percentage =
          case job.progress do
            %{"percentage" => percentage} -> percentage
            %{percentage: percentage} -> percentage
            _ -> 0
          end

        # Get current stage from progress field
        current_stage =
          case job.progress do
            %{"stage" => stage} -> stage
            %{stage: stage} -> stage
            _ -> "unknown"
          end

        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job.id,
          type: job.type,
          status: job.status,
          video_name: job.video_name,
          estimated_cost: job.estimated_cost,
          costs: job_cost_summary(job),
          progress_percentage: progress_percentage,
          current_stage: current_stage,
          parameters: job.parameters,
          storyboard: job.storyboard,
          inserted_at: job.inserted_at,
          updated_at: job.updated_at
        })
    end
  end

  @doc """
  GET /api/v3/generated-videos

  Lists recently generated videos filtered by job ID, campaign, and/or client.
  """
  def generated_videos(conn, params) do
    campaign_id = Map.get(params, "campaign_id") || Map.get(params, "campaignId")
    client_id = Map.get(params, "client_id") || Map.get(params, "clientId")
    job_id_param = Map.get(params, "job_id") || Map.get(params, "jobId")
    job_id = parse_int(job_id_param, nil)

    limit =
      params
      |> Map.get("limit")
      |> parse_int(@default_limit)
      |> min(@max_limit)
      |> max(1)

    offset =
      params
      |> Map.get("offset")
      |> parse_int(0)
      |> max(0)

    videos_query =
      Job
      |> where([j], j.status == :completed)
      |> where([j], not is_nil(j.result))
      |> maybe_filter_job(:job_id, job_id)
      |> maybe_filter_job(:campaign_id, campaign_id)
      |> maybe_filter_job(:client_id, client_id)
      |> order_by([j], desc: j.inserted_at)
      |> limit(^limit)
      |> offset(^offset)

    videos = Repo.all(videos_query)

    json(conn, %{
      data: Enum.map(videos, &job_video_json/1),
      meta: %{
        count: length(videos),
        limit: limit,
        offset: offset
      }
    })
  end

  @doc false
  @spec open_api_operation(atom) :: Operation.t()
  def open_api_operation(action) do
    apply(__MODULE__, :"#{action}_operation", [])
  end

  def approve_operation do
    %Operation{
      tags: ["jobs"],
      summary: "Approve job",
      description: "Transition a pending job into processing by dispatching it to the workflow.",
      operationId: "JobController.approve",
      parameters: [
        parameter(:id, :path, :integer, "Job ID", example: 123)
      ],
      responses: %{
        200 => response("Approval response", "application/json", JobApprovalResponse)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["jobs"],
      summary: "Get job",
      description: "Returns current status, progress, and storyboard metadata for a job.",
      operationId: "JobController.show",
      parameters: [
        parameter(:id, :path, :integer, "Job ID", example: 123)
      ],
      responses: %{
        200 => response("Job response", "application/json", JobShowResponse)
      }
    }
  end

  def generated_videos_operation do
    %Operation{
      tags: ["jobs"],
      summary: "List generated videos",
      description:
        "Returns recently completed jobs with rendered videos filtered by job ID, campaign, and/or client.",
      operationId: "JobController.generated_videos",
      parameters: [
        parameter(:job_id, :query, :integer, "Filter by job ID", example: 123),
        parameter(:campaign_id, :query, :string, "Filter by campaign ID",
          example: "313e2460-2520-401b-86f4-385ebe41d4b8"
        ),
        parameter(:client_id, :query, :string, "Filter by client ID",
          example: "5ad559d3-d10b-4ec2-a3d5-0e049416b1c1"
        ),
        parameter(:limit, :query, :integer, "Max records to return", example: 25),
        parameter(:offset, :query, :integer, "Offset for pagination", example: 0)
      ],
      responses: %{
        200 =>
          response("Generated videos", "application/json", %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              data: %OpenApiSpex.Schema{
                type: :array,
                items: %OpenApiSpex.Schema{
                  type: :object,
                  properties: %{
                    job_id: %OpenApiSpex.Schema{type: :integer},
                    video_name: %OpenApiSpex.Schema{type: :string, nullable: true},
                    status: %OpenApiSpex.Schema{type: :string},
                    type: %OpenApiSpex.Schema{type: :string},
                    estimated_cost: %OpenApiSpex.Schema{type: :number, format: :float, nullable: true},
                    costs: %OpenApiSpex.Schema{
                      type: :object,
                      nullable: true,
                      properties: %{
                        estimated: %OpenApiSpex.Schema{type: :number, format: :float},
                        currency: %OpenApiSpex.Schema{type: :string}
                      }
                    },
                    campaign_id: %OpenApiSpex.Schema{type: :string, nullable: true},
                    client_id: %OpenApiSpex.Schema{type: :string, nullable: true},
                    inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
                    updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
                    storyboard: %OpenApiSpex.Schema{
                      type: :object,
                      nullable: true,
                      description: "Storyboard with scenes (each containing asset_ids, duration, etc.) and total_duration",
                      properties: %{
                        scenes: %OpenApiSpex.Schema{
                          type: :array,
                          items: %OpenApiSpex.Schema{
                            type: :object,
                            properties: %{
                              title: %OpenApiSpex.Schema{type: :string},
                              description: %OpenApiSpex.Schema{type: :string},
                              duration: %OpenApiSpex.Schema{type: :number},
                              scene_type: %OpenApiSpex.Schema{type: :string},
                              asset_ids: %OpenApiSpex.Schema{
                                type: :array,
                                items: %OpenApiSpex.Schema{type: :string, format: :uuid},
                                description: "Asset UUIDs for this scene's images"
                              },
                              highlights: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
                              transition: %OpenApiSpex.Schema{type: :string}
                            }
                          }
                        },
                        total_duration: %OpenApiSpex.Schema{type: :number}
                      }
                    },
                    video_url: %OpenApiSpex.Schema{type: :string},
                    total_duration: %OpenApiSpex.Schema{type: :number, nullable: true}
                  },
                  required: [:job_id, :status, :type, :video_url]
                }
              },
              meta: %OpenApiSpex.Schema{
                type: :object,
                properties: %{
                  count: %OpenApiSpex.Schema{type: :integer},
                  limit: %OpenApiSpex.Schema{type: :integer},
                  offset: %OpenApiSpex.Schema{type: :integer}
                },
                required: [:count, :limit, :offset]
              }
            },
            required: [:data, :meta]
          })
      }
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp maybe_filter_job(query, _field, nil), do: query

  defp maybe_filter_job(query, _field, ""), do: query

  defp maybe_filter_job(query, :campaign_id, value) do
    where(query, [j], fragment("json_extract(?, '$.campaign_id') = ?", j.parameters, ^value))
  end

  defp maybe_filter_job(query, :client_id, value) do
    where(query, [j], fragment("json_extract(?, '$.client_id') = ?", j.parameters, ^value))
  end

  defp maybe_filter_job(query, :job_id, value) when is_integer(value) do
    where(query, [j], j.id == ^value)
  end

  defp maybe_filter_job(query, :job_id, _), do: query

  defp job_video_json(job) do
    params = job.parameters || %{}

    %{
      job_id: job.id,
      video_name: job.video_name,
      status: job.status,
      type: job.type,
      estimated_cost: job.estimated_cost,
      costs: job_cost_summary(job),
      campaign_id: fetch_param(params, "campaign_id"),
      client_id: fetch_param(params, "client_id"),
      inserted_at: job.inserted_at,
      updated_at: job.updated_at,
      storyboard: job.storyboard,
      total_duration: storyboard_value(job.storyboard, "total_duration"),
      video_url: "/api/v3/videos/#{job.id}/combined"
    }
  end

  defp fetch_param(map, key) when is_map(map) do
    map[key] ||
      case safe_to_existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(map, atom_key)
      end
  end

  defp fetch_param(_, _), do: nil

  defp storyboard_value(nil, _key), do: nil

  defp storyboard_value(storyboard, key) when is_map(storyboard) do
    storyboard[key] ||
      case safe_to_existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(storyboard, atom_key)
      end
  end

  defp job_cost_summary(job) do
    params = job.parameters || %{}
    progress = job.progress || %{}

    summary =
      Map.get(progress, "costs") ||
        Map.get(progress, :costs)

    cond do
      is_map(summary) and summary != %{} ->
        summary

      true ->
        estimated = job.estimated_cost || fetch_param(params, "estimated_cost")
        currency = fetch_param(params, "cost_currency") || "USD"

        %{
          "estimated" => estimated,
          "currency" => currency
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Enum.into(%{})
    end
  end

  defp safe_to_existing_atom(nil), do: nil

  defp safe_to_existing_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_id(%{"id" => id}), do: normalize_id(id)
  defp normalize_id(%{id: id}), do: normalize_id(id)
  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
end
