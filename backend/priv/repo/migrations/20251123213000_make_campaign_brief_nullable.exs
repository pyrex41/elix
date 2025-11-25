defmodule Backend.Repo.Migrations.MakeCampaignBriefNullable do
  use Ecto.Migration

  def up do
    # Check if brief column is already nullable by checking if we can insert null
    # If migration already ran, brief is nullable and we skip
    case repo().query("SELECT sql FROM sqlite_master WHERE type='table' AND name='campaigns';") do
      {:ok, %{rows: [[sql]]}} ->
        # If brief is NOT NULL in the schema, we need to migrate
        if String.contains?(sql, "brief TEXT NOT NULL") do
          do_migration()
        else
          # Already nullable, skip
          :ok
        end

      _ ->
        # Table doesn't exist or other error, let base migration handle it
        :ok
    end
  end

  defp do_migration do
    execute("""
    CREATE TABLE IF NOT EXISTS campaigns_tmp (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      brief TEXT,
      goal TEXT,
      status TEXT,
      product_url TEXT,
      metadata TEXT,
      client_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY(client_id) REFERENCES clients(id) ON DELETE CASCADE
    );
    """)

    execute("""
    INSERT OR IGNORE INTO campaigns_tmp (id, name, brief, goal, status, product_url, metadata, client_id, inserted_at, updated_at)
    SELECT id, name, brief, goal, status, product_url, metadata, client_id, inserted_at, updated_at FROM campaigns;
    """)

    execute("DROP TABLE campaigns;")
    execute("ALTER TABLE campaigns_tmp RENAME TO campaigns;")
    execute("CREATE INDEX IF NOT EXISTS campaigns_client_id_index ON campaigns (client_id);")
  end

  def down do
    :ok
  end
end
