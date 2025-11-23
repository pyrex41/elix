defmodule BackendWeb.Api.V3.ClientController do
  @moduledoc """
  Controller for client management endpoints in API v3.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Client, Campaign, Job}

  alias BackendWeb.ApiSchemas.{
    ClientRequest,
    ClientResponse,
    ClientListResponse,
    ClientStatsResponse,
    CampaignListResponse,
    ErrorResponse
  }

  alias OpenApiSpex.{Operation, Schema}
  import OpenApiSpex.Operation, only: [parameter: 5, request_body: 4, response: 3]
  import Ecto.Query
  require Logger

  def index(conn, _params) do
    clients = Repo.all(Client)

    json(conn, %{
      data: Enum.map(clients, &client_json/1),
      meta: %{total: length(clients)}
    })
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Client, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Client not found", code: "not_found"}})

      client ->
        json(conn, %{data: client_json(client)})
    end
  end

  def create(conn, params) do
    changeset = Client.changeset(%Client{}, params)

    case Repo.insert(changeset) do
      {:ok, client} ->
        conn
        |> put_status(:created)
        |> json(%{data: client_json(client)})

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
    case Repo.get(Client, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Client not found", code: "not_found"}})

      client ->
        changeset = Client.changeset(client, params)

        case Repo.update(changeset) do
          {:ok, updated_client} ->
            json(conn, %{data: client_json(updated_client)})

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
    case Repo.get(Client, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Client not found", code: "not_found"}})

      client ->
        Repo.delete!(client)
        send_resp(conn, :no_content, "")
    end
  end

  def get_campaigns(conn, %{"id" => client_id}) do
    case Repo.get(Client, client_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Client not found", code: "not_found"}})

      _client ->
        campaigns = Repo.all(from(c in Campaign, where: c.client_id == ^client_id))

        json(conn, %{
          data: Enum.map(campaigns, &campaign_json/1),
          meta: %{
            client_id: client_id,
            total: length(campaigns)
          }
        })
    end
  end

  def stats(conn, %{"id" => client_id}) do
    case Repo.get(Client, client_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "Client not found", code: "not_found"}})

      _client ->
        json(conn, %{data: build_client_stats(client_id)})
    end
  end

  @doc false
  @spec open_api_operation(atom) :: Operation.t()
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
      tags: ["clients"],
      summary: "List clients",
      description: "Returns all clients.",
      operationId: "ClientController.index",
      responses: %{
        200 => response("Client list", "application/json", ClientListResponse)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["clients"],
      summary: "Get client",
      operationId: "ClientController.show",
      parameters: [
        parameter(:id, :path, :string, "Client ID",
          example: "b6f9fdd3-2c88-4aa4-8857-8a1da43e3bb8"
        )
      ],
      responses: %{
        200 => response("Client", "application/json", ClientResponse),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  def create_operation do
    %Operation{
      tags: ["clients"],
      summary: "Create client",
      operationId: "ClientController.create",
      requestBody:
        request_body("Client payload", "application/json", ClientRequest, required: true),
      responses: %{
        201 => response("Created", "application/json", ClientResponse),
        422 => response("Validation error", "application/json", ErrorResponse)
      }
    }
  end

  def update_operation do
    %Operation{
      tags: ["clients"],
      summary: "Update client",
      operationId: "ClientController.update",
      parameters: [
        parameter(:id, :path, :string, "Client ID",
          example: "b6f9fdd3-2c88-4aa4-8857-8a1da43e3bb8"
        )
      ],
      requestBody:
        request_body("Client payload", "application/json", ClientRequest, required: true),
      responses: %{
        200 => response("Updated", "application/json", ClientResponse),
        404 => response("Not found", "application/json", ErrorResponse),
        422 => response("Validation error", "application/json", ErrorResponse)
      }
    }
  end

  def delete_operation do
    %Operation{
      tags: ["clients"],
      summary: "Delete client",
      operationId: "ClientController.delete",
      parameters: [
        parameter(:id, :path, :string, "Client ID",
          example: "b6f9fdd3-2c88-4aa4-8857-8a1da43e3bb8"
        )
      ],
      responses: %{
        204 => response("Deleted", "application/json", %Schema{type: :null}),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  def get_campaigns_operation do
    %Operation{
      tags: ["clients"],
      summary: "List campaigns for client",
      operationId: "ClientController.get_campaigns",
      parameters: [
        parameter(:id, :path, :string, "Client ID",
          example: "b6f9fdd3-2c88-4aa4-8857-8a1da43e3bb8"
        )
      ],
      responses: %{
        200 => response("Campaigns", "application/json", CampaignListResponse),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  def stats_operation do
    %Operation{
      tags: ["clients"],
      summary: "Client stats",
      operationId: "ClientController.stats",
      parameters: [
        parameter(:id, :path, :string, "Client ID",
          example: "b6f9fdd3-2c88-4aa4-8857-8a1da43e3bb8"
        )
      ],
      responses: %{
        200 => response("Stats", "application/json", ClientStatsResponse),
        404 => response("Not found", "application/json", ErrorResponse)
      }
    }
  end

  # Private helpers

  defp client_json(client) do
    %{
      id: client.id,
      name: client.name,
      description: client.description,
      homepage: client.homepage,
      metadata: client.metadata,
      brand_guidelines: client.brand_guidelines,
      inserted_at: client.inserted_at,
      updated_at: client.updated_at
    }
  end

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

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp build_client_stats(client_id) do
    campaign_query = from(c in Campaign, where: c.client_id == ^client_id)

    campaign_count = Repo.aggregate(campaign_query, :count, :id)

    job_count =
      Repo.aggregate(
        from(j in Job,
          join: c in subquery(campaign_query),
          on: fragment("json_extract(?, '$.campaign_id') = ?", j.parameters, c.id)
        ),
        :count,
        :id
      )

    %{
      campaignCount: campaign_count,
      videoCount: job_count,
      totalSpend: 0.0
    }
  end
end
