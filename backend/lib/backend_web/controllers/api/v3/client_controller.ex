defmodule BackendWeb.Api.V3.ClientController do
  @moduledoc """
  Controller for client management endpoints in API v3.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Client, Campaign, Job}
  alias BackendWeb.Schemas.{ClientSchemas, CampaignSchemas, CommonSchemas}
  alias OpenApiSpex.Operation
  import Ecto.Query
  require Logger

  @doc """
  OpenAPI operation specification callback
  """
  def open_api_operation(action) do
    operation = String.to_existing_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def index_operation do
    %Operation{
      tags: ["Clients"],
      summary: "List all clients",
      description: "Retrieve a list of all clients",
      operationId: "ClientController.index",
      security: [%{"api_key" => []}],
      responses: %{
        200 => Operation.response("Clients", "application/json", ClientSchemas.ClientsResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["Clients"],
      summary: "Get client by ID",
      description: "Retrieve a single client by its ID",
      operationId: "ClientController.show",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Client ID", example: "123e4567-e89b-12d3-a456-426614174000")
      ],
      responses: %{
        200 => Operation.response("Client", "application/json", ClientSchemas.ClientResponse),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def create_operation do
    %Operation{
      tags: ["Clients"],
      summary: "Create a new client",
      description: "Create a new client with the provided attributes",
      operationId: "ClientController.create",
      security: [%{"api_key" => []}],
      requestBody:
        Operation.request_body("Client attributes", "application/json", ClientSchemas.ClientRequest, required: true),
      responses: %{
        201 => Operation.response("Client created", "application/json", ClientSchemas.ClientResponse),
        422 =>
          Operation.response("Validation error", "application/json", CommonSchemas.ValidationErrorResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def update_operation do
    %Operation{
      tags: ["Clients"],
      summary: "Update a client",
      description: "Update an existing client's attributes",
      operationId: "ClientController.update",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Client ID", example: "123e4567-e89b-12d3-a456-426614174000")
      ],
      requestBody:
        Operation.request_body("Client attributes", "application/json", ClientSchemas.ClientRequest, required: true),
      responses: %{
        200 => Operation.response("Client updated", "application/json", ClientSchemas.ClientResponse),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        422 =>
          Operation.response("Validation error", "application/json", CommonSchemas.ValidationErrorResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def delete_operation do
    %Operation{
      tags: ["Clients"],
      summary: "Delete a client",
      description: "Delete a client by ID",
      operationId: "ClientController.delete",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Client ID", example: "123e4567-e89b-12d3-a456-426614174000")
      ],
      responses: %{
        204 => Operation.response("No Content", "application/json", CommonSchemas.NoContentResponse),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def get_campaigns_operation do
    %Operation{
      tags: ["Clients"],
      summary: "Get client's campaigns",
      description: "Retrieve all campaigns for a specific client",
      operationId: "ClientController.get_campaigns",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Client ID", example: "123e4567-e89b-12d3-a456-426614174000")
      ],
      responses: %{
        200 =>
          Operation.response("Campaigns", "application/json", CampaignSchemas.CampaignsResponse),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def stats_operation do
    %Operation{
      tags: ["Clients"],
      summary: "Get client statistics",
      description: "Retrieve statistics for a specific client",
      operationId: "ClientController.stats",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Client ID", example: "123e4567-e89b-12d3-a456-426614174000")
      ],
      responses: %{
        200 => Operation.response("Client stats", "application/json", ClientSchemas.ClientStats),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        401 =>
          Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

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
