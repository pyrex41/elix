defmodule Backend.Repo.Migrations.AddNameToAssets do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE assets ADD COLUMN name TEXT;")
  end

  def down do
    drop_asset_triggers_and_indexes()
    execute("ALTER TABLE assets RENAME TO assets_with_name;")

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
    FROM assets_with_name;
    """)

    execute("DROP TABLE assets_with_name;")
    create_asset_indexes()
    create_asset_type_triggers()
  end

  defp drop_asset_triggers_and_indexes do
    execute("DROP INDEX IF EXISTS assets_campaign_id_index;")
    execute("DROP INDEX IF EXISTS assets_client_id_index;")
    execute("DROP INDEX IF EXISTS assets_type_index;")
    execute("DROP TRIGGER IF EXISTS validate_asset_type_insert;")
    execute("DROP TRIGGER IF EXISTS validate_asset_type_update;")
  end

  defp create_asset_indexes do
    execute("CREATE INDEX assets_campaign_id_index ON assets (campaign_id);")
    execute("CREATE INDEX assets_client_id_index ON assets (client_id);")
    execute("CREATE INDEX assets_type_index ON assets (type);")
  end

  defp create_asset_type_triggers do
    execute("""
    CREATE TRIGGER validate_asset_type_insert
    BEFORE INSERT ON assets
    FOR EACH ROW
    WHEN NEW.type NOT IN ('image', 'video', 'audio')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid asset type');
    END;
    """)

    execute("""
    CREATE TRIGGER validate_asset_type_update
    BEFORE UPDATE ON assets
    FOR EACH ROW
    WHEN NEW.type NOT IN ('image', 'video', 'audio')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid asset type');
    END;
    """)
  end
end
