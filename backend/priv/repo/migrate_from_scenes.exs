#!/usr/bin/env elixir

# Migration script to import data from scenes.db to the new Phoenix backend database
# Usage: mix run priv/repo/migrate_from_scenes.exs

defmodule DataMigration do
  alias Backend.Repo
  alias Backend.Schemas.{Client, Campaign, Asset}
  require Logger

  @scenes_db_path "/Users/reuben/gauntlet/video/elix/scenes.db"

  def run do
    Logger.info("Starting data migration from scenes.db...")

    # Connect to the old database
    {:ok, conn} = Exqlite.Sqlite3.open(@scenes_db_path)

    # Migrate clients
    Logger.info("Migrating clients...")
    migrate_clients(conn)

    # Migrate campaigns
    Logger.info("Migrating campaigns...")
    migrate_campaigns(conn)

    # Migrate assets with blobs
    Logger.info("Migrating assets...")
    migrate_assets(conn)

    # Close connection
    :ok = Exqlite.Sqlite3.close(conn)

    Logger.info("Migration completed successfully!")
  end

  defp migrate_clients(conn) do
    query = "SELECT id, name, brand_guidelines FROM clients"
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, query)

    clients = fetch_all(conn, statement)

    Enum.each(clients, fn [id, name, brand_guidelines] ->
      case Repo.get(Client, id) do
        nil ->
          %Client{}
          |> Client.migration_changeset(%{
            id: id,
            name: name || "Unnamed Client",
            brand_guidelines: brand_guidelines
          })
          |> Repo.insert!()

          Logger.info("  Imported client: #{name || id}")

        existing ->
          Logger.info("  Client already exists: #{existing.name}")
      end
    end)

    :ok = Exqlite.Sqlite3.release(conn, statement)
  end

  defp migrate_campaigns(conn) do
    query = """
    SELECT id, client_id, name, brief
    FROM campaigns
    WHERE client_id IN (SELECT id FROM clients)
    """
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, query)

    campaigns = fetch_all(conn, statement)

    Enum.each(campaigns, fn [id, client_id, name, brief] ->
      case Repo.get(Campaign, id) do
        nil ->
          # Verify client exists in our DB
          if Repo.get(Client, client_id) do
            %Campaign{}
            |> Campaign.migration_changeset(%{
              id: id,
              client_id: client_id,
              name: name || "Unnamed Campaign",
              brief: brief || "No brief provided"
            })
            |> Repo.insert!()

            Logger.info("  Imported campaign: #{name || id}")
          else
            Logger.warning("  Skipping campaign #{id} - client #{client_id} not found")
          end

        existing ->
          Logger.info("  Campaign already exists: #{existing.name}")
      end
    end)

    :ok = Exqlite.Sqlite3.release(conn, statement)
  end

  defp migrate_assets(conn) do
    # Query to get assets with their blob data
    query = """
    SELECT
      a.id,
      a.campaign_id,
      a.asset_type,
      a.source_url,
      a.blob_id,
      ab.data,
      ab.content_type,
      a.tags,
      a.name
    FROM assets a
    LEFT JOIN asset_blobs ab ON a.blob_id = ab.id
    WHERE a.campaign_id IN (SELECT id FROM campaigns)
      AND a.asset_type = 'image'
      AND (a.source_url IS NOT NULL OR ab.data IS NOT NULL)
    """

    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, query)
    assets = fetch_all(conn, statement)

    Logger.info("  Found #{length(assets)} assets to migrate")

    Enum.each(assets, fn [id, campaign_id, asset_type, source_url, _blob_id, blob_data, content_type, tags, name] ->
      case Repo.get(Asset, id) do
        nil ->
          # Verify campaign exists in our DB
          if Repo.get(Campaign, campaign_id) do
            # Determine asset type from content_type or default to :image
            type = determine_asset_type(content_type, asset_type)

            # Parse tags as metadata
            metadata = parse_metadata(tags, name, content_type)

            %Asset{}
            |> Asset.migration_changeset(%{
              id: id,
              campaign_id: campaign_id,
              type: type,
              source_url: source_url,
              blob_data: blob_data,
              metadata: metadata
            })
            |> Repo.insert!()

            size_info = if blob_data, do: " (#{byte_size(blob_data)} bytes)", else: ""
            Logger.info("  Imported asset: #{id}#{size_info}")
          else
            Logger.warning("  Skipping asset #{id} - campaign #{campaign_id} not found")
          end

        existing ->
          Logger.info("  Asset already exists: #{existing.id}")
      end
    end)

    :ok = Exqlite.Sqlite3.release(conn, statement)
  end

  defp fetch_all(conn, statement) do
    fetch_all(conn, statement, [])
  end

  defp fetch_all(conn, statement, acc) do
    case Exqlite.Sqlite3.step(conn, statement) do
      {:row, row} -> fetch_all(conn, statement, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp determine_asset_type(content_type, default_type) do
    cond do
      content_type && String.starts_with?(content_type, "image/") -> :image
      content_type && String.starts_with?(content_type, "video/") -> :video
      content_type && String.starts_with?(content_type, "audio/") -> :audio
      default_type == "image" -> :image
      default_type == "video" -> :video
      default_type == "audio" -> :audio
      true -> :image
    end
  end

  defp parse_metadata(tags, name, content_type) do
    %{}
    |> Map.put_new("tags", tags)
    |> Map.put_new("original_name", name)
    |> Map.put_new("content_type", content_type)
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.into(%{})
  end
end

# Run the migration
DataMigration.run()