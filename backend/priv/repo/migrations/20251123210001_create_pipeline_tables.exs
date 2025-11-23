defmodule Backend.Repo.Migrations.CreatePipelineTables do
  use Ecto.Migration

  def change do
    # Pipelines table
    create table(:pipelines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "draft"
      add :metadata, :text, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:pipelines, [:status])

    # Add CHECK constraint for status enum
    create constraint(:pipelines, :valid_status,
             check: "status IN ('draft', 'active', 'archived')"
           )

    # Nodes table
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :type, :text, null: false
      add :config, :text, null: false, default: "{}"
      add :position, :text, default: "{\"x\": 0, \"y\": 0}"
      add :metadata, :text, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:nodes, [:pipeline_id])
    create index(:nodes, [:type])

    # Add CHECK constraint for node type enum
    create constraint(:nodes, :valid_type,
             check: "type IN ('text', 'http_request', 'llm', 'condition', 'transform')"
           )

    # Edges table
    create table(:edges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_node_id, references(:nodes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_node_id, references(:nodes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_handle, :text
      add :target_handle, :text
      add :metadata, :text, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:edges, [:pipeline_id])
    create index(:edges, [:source_node_id])
    create index(:edges, [:target_node_id])

    # Unique constraint for edges
    create unique_index(:edges, [:source_node_id, :target_node_id, :source_handle, :target_handle],
             name: :unique_edge_index
           )

    # Pipeline Runs table
    create table(:pipeline_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pipeline_id, references(:pipelines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :text, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error_message, :text
      add :input_data, :text, null: false, default: "{}"
      add :output_data, :text, default: "{}"
      add :metadata, :text, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:pipeline_runs, [:pipeline_id])
    create index(:pipeline_runs, [:status])
    create index(:pipeline_runs, [:inserted_at])

    # Add CHECK constraint for pipeline_run status enum
    create constraint(:pipeline_runs, :valid_status,
             check: "status IN ('pending', 'running', 'completed', 'failed', 'cancelled')"
           )

    # Node Results table
    create table(:node_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pipeline_run_id,
          references(:pipeline_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :input_data, :text, default: "{}"
      add :output_data, :text, default: "{}"
      add :error_message, :text
      add :metadata, :text, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:node_results, [:pipeline_run_id])
    create index(:node_results, [:node_id])
    create index(:node_results, [:status])

    # Add CHECK constraint for node_result status enum
    create constraint(:node_results, :valid_status,
             check: "status IN ('pending', 'running', 'completed', 'failed', 'skipped')"
           )
  end
end
