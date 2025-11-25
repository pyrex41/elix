defmodule Backend.Repo.Migrations.UpdateAssetsAddClientAndTags do
  use Ecto.Migration

  def up do
    # Check if migration already applied by looking for client_id column
    columns = get_column_names("assets")

    if "client_id" in columns do
      # Migration already applied, ensure indexes and triggers exist
      ensure_indexes_and_triggers()
    else
      # Need to run migration
      do_migration()
    end
  end

  defp do_migration do
    drop_asset_triggers_and_indexes()

    execute("ALTER TABLE assets RENAME TO assets_old;")

    execute("""
    CREATE TABLE assets (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      blob_data BLOB,
      metadata TEXT,
      source_url TEXT,
      description TEXT,
      tags TEXT,
      campaign_id TEXT,
      client_id TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY(campaign_id) REFERENCES campaigns(id) ON DELETE CASCADE,
      FOREIGN KEY(client_id) REFERENCES clients(id) ON DELETE CASCADE,
      CHECK (campaign_id IS NOT NULL OR client_id IS NOT NULL)
    );
    """)

    execute("""
    INSERT INTO assets (
      id,
      type,
      blob_data,
      metadata,
      source_url,
      description,
      tags,
      campaign_id,
      client_id,
      inserted_at,
      updated_at
    )
    SELECT
      a.id,
      a.type,
      a.blob_data,
      a.metadata,
      a.source_url,
      json_extract(a.metadata, '$.description'),
      json_extract(a.metadata, '$.tags'),
      a.campaign_id,
      c.client_id,
      a.inserted_at,
      a.updated_at
    FROM assets_old AS a
    LEFT JOIN campaigns AS c ON c.id = a.campaign_id;
    """)

    execute("DROP TABLE assets_old;")

    ensure_indexes_and_triggers()
  end

  defp ensure_indexes_and_triggers do
    execute("CREATE INDEX IF NOT EXISTS assets_campaign_id_index ON assets (campaign_id);")
    execute("CREATE INDEX IF NOT EXISTS assets_client_id_index ON assets (client_id);")
    execute("CREATE INDEX IF NOT EXISTS assets_type_index ON assets (type);")

    execute("""
    CREATE TRIGGER IF NOT EXISTS validate_asset_type_insert
    BEFORE INSERT ON assets
    FOR EACH ROW
    WHEN NEW.type NOT IN ('image', 'video', 'audio')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid asset type');
    END;
    """)

    execute("""
    CREATE TRIGGER IF NOT EXISTS validate_asset_type_update
    BEFORE UPDATE ON assets
    FOR EACH ROW
    WHEN NEW.type NOT IN ('image', 'video', 'audio')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid asset type');
    END;
    """)
  end

  def down do
    :ok
  end

  defp drop_asset_triggers_and_indexes do
    execute("DROP INDEX IF EXISTS assets_campaign_id_index;")
    execute("DROP INDEX IF EXISTS assets_type_index;")
    execute("DROP INDEX IF EXISTS assets_client_id_index;")
    execute("DROP TRIGGER IF EXISTS validate_asset_type_insert;")
    execute("DROP TRIGGER IF EXISTS validate_asset_type_update;")
  end

  defp get_column_names(table) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table});")
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end
end
