defmodule Backend.Repo.Migrations.MakeCampaignBriefNullable do
  use Ecto.Migration

  def up do
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
    INSERT INTO campaigns_tmp (id, name, brief, goal, status, product_url, metadata, client_id, inserted_at, updated_at)
    SELECT id, name, brief, goal, status, product_url, metadata, client_id, inserted_at, updated_at FROM campaigns;
    """)

    execute("DROP TABLE campaigns;")
    execute("ALTER TABLE campaigns_tmp RENAME TO campaigns;")
    execute("CREATE INDEX IF NOT EXISTS campaigns_client_id_index ON campaigns (client_id);")
  end

  def down do
    execute("""
    CREATE TABLE IF NOT EXISTS campaigns_tmp (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      brief TEXT NOT NULL,
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
    INSERT INTO campaigns_tmp (id, name, brief, goal, status, product_url, metadata, client_id, inserted_at, updated_at)
    SELECT id, name, COALESCE(brief, ''), goal, status, product_url, metadata, client_id, inserted_at, updated_at FROM campaigns;
    """)

    execute("DROP TABLE campaigns;")
    execute("ALTER TABLE campaigns_tmp RENAME TO campaigns;")
    execute("CREATE INDEX IF NOT EXISTS campaigns_client_id_index ON campaigns (client_id);")
  end
end
