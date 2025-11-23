defmodule Backend.Pipelines.Resources.NodeResult do
  @moduledoc """
  A NodeResult represents the output of a single node execution within a pipeline run.
  """

  use Ash.Resource,
    domain: Backend.Pipelines.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [
      AshJsonApi.Resource,
      AshStateMachine
    ]

  sqlite do
    repo Backend.Repo
    table "node_results"
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
    end

    attribute :started_at, :utc_datetime do
      public? true
    end

    attribute :completed_at, :utc_datetime do
      public? true
    end

    attribute :input_data, :map do
      default %{}
      public? true
      description "Data passed to this node from previous nodes"
    end

    attribute :output_data, :map do
      default %{}
      public? true
      description "Data produced by this node"
    end

    attribute :error_message, :string do
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Execution metadata: tokens used, duration, retry count, etc."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :start do
        from :pending
        to :running
      end

      transition :complete do
        from :running
        to :completed
      end

      transition :fail do
        from [:pending, :running]
        to :failed
      end

      transition :skip do
        from :pending
        to :skipped
      end
    end
  end

  relationships do
    belongs_to :pipeline_run, Backend.Pipelines.Resources.PipelineRun do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :node, Backend.Pipelines.Resources.Node do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:pipeline_run_id, :node_id, :input_data, :metadata]
    end

    update :start do
      accept []
      change transition_state(:running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :complete do
      accept [:output_data, :metadata]
      change transition_state(:completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:error_message, :metadata]
      change transition_state(:failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :skip do
      accept []
      change transition_state(:skipped)
    end
  end

  calculations do
    calculate :duration, :integer do
      calculation fn records, _context ->
        Enum.map(records, fn record ->
          if record.started_at && record.completed_at do
            DateTime.diff(record.completed_at, record.started_at, :millisecond)
          else
            nil
          end
        end)
      end
    end

    calculate :retry_count, :integer do
      calculation fn records, _context ->
        Enum.map(records, fn record ->
          get_in(record.metadata, ["retry_count"]) || 0
        end)
      end
    end
  end

  json_api do
    type "node_result"

    routes do
      base "/node_results"

      get :read
      index :read
      post :create
      delete :destroy
    end
  end

  code_interface do
    define :create
    define :read
    define :destroy
    define :start
    define :complete, args: [:output_data, :metadata]
    define :fail, args: [:error_message, :metadata]
    define :skip
  end
end
