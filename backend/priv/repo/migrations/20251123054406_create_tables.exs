defmodule Backend.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def up do
    # Enable SQLite WAL mode for better concurrent access
    execute("PRAGMA journal_mode=WAL;")

    # Create users table with integer id
    create table(:users) do
      add :username, :string, null: false
      add :email, :string, null: false
      add :password_hash, :string
      add :api_key_hash, :string

      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:username])

    # Create clients table with UUID id
    create table(:clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :brand_guidelines, :string

      timestamps()
    end

    # Create campaigns table with UUID id
    create table(:campaigns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :brief, :string, null: false
      add :client_id, references(:clients, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:campaigns, [:client_id])

    # Create assets table with UUID id
    create table(:assets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :blob_data, :binary
      add :metadata, :map
      add :source_url, :string

      add :campaign_id, references(:campaigns, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps()
    end

    create index(:assets, [:campaign_id])
    create index(:assets, [:type])

    # Create jobs table with integer id
    create table(:jobs) do
      add :type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :parameters, :map
      add :storyboard, :map
      add :progress, :map
      add :result, :binary
      add :audio_blob, :binary

      timestamps()
    end

    create index(:jobs, [:status])
    create index(:jobs, [:type])

    # Create sub_jobs table with UUID id
    create table(:sub_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_id, :string
      add :status, :string, null: false, default: "pending"
      add :video_blob, :binary
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:sub_jobs, [:job_id])
    create index(:sub_jobs, [:status])
    create index(:sub_jobs, [:provider_id])

    # Add check constraints for enum types using raw SQL
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

    execute("""
    CREATE TRIGGER validate_job_type_insert
    BEFORE INSERT ON jobs
    FOR EACH ROW
    WHEN NEW.type NOT IN ('image_pairs', 'property_photos')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid job type');
    END;
    """)

    execute("""
    CREATE TRIGGER validate_job_type_update
    BEFORE UPDATE ON jobs
    FOR EACH ROW
    WHEN NEW.type NOT IN ('image_pairs', 'property_photos')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid job type');
    END;
    """)

    execute("""
    CREATE TRIGGER validate_job_status_insert
    BEFORE INSERT ON jobs
    FOR EACH ROW
    WHEN NEW.status NOT IN ('pending', 'approved', 'processing', 'completed', 'failed')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid job status');
    END;
    """)

    execute("""
    CREATE TRIGGER validate_job_status_update
    BEFORE UPDATE ON jobs
    FOR EACH ROW
    WHEN NEW.status NOT IN ('pending', 'approved', 'processing', 'completed', 'failed')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid job status');
    END;
    """)

    execute("""
    CREATE TRIGGER validate_sub_job_status_insert
    BEFORE INSERT ON sub_jobs
    FOR EACH ROW
    WHEN NEW.status NOT IN ('pending', 'processing', 'completed', 'failed')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid sub_job status');
    END;
    """)

    execute("""
    CREATE TRIGGER validate_sub_job_status_update
    BEFORE UPDATE ON sub_jobs
    FOR EACH ROW
    WHEN NEW.status NOT IN ('pending', 'processing', 'completed', 'failed')
    BEGIN
      SELECT RAISE(ABORT, 'Invalid sub_job status');
    END;
    """)
  end

  def down do
    # Drop triggers first
    execute("DROP TRIGGER IF EXISTS validate_asset_type_insert;")
    execute("DROP TRIGGER IF EXISTS validate_asset_type_update;")
    execute("DROP TRIGGER IF EXISTS validate_job_type_insert;")
    execute("DROP TRIGGER IF EXISTS validate_job_type_update;")
    execute("DROP TRIGGER IF EXISTS validate_job_status_insert;")
    execute("DROP TRIGGER IF EXISTS validate_job_status_update;")
    execute("DROP TRIGGER IF EXISTS validate_sub_job_status_insert;")
    execute("DROP TRIGGER IF EXISTS validate_sub_job_status_update;")

    # Drop tables in reverse order (respecting foreign key constraints)
    drop table(:sub_jobs)
    drop table(:jobs)
    drop table(:assets)
    drop table(:campaigns)
    drop table(:clients)
    drop table(:users)
  end
end
