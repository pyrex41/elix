defmodule BackendWeb.Api.V3.ClientController do
  @moduledoc """
  Controller for client management endpoints in API v3.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Client, Campaign}
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
        campaigns = Repo.all(from c in Campaign, where: c.client_id == ^client_id)

        json(conn, %{
          data: Enum.map(campaigns, &campaign_json/1),
          meta: %{
            client_id: client_id,
            total: length(campaigns)
          }
        })
    end
  end

  # Private helpers

  defp client_json(client) do
    %{
      id: client.id,
      name: client.name,
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
end
