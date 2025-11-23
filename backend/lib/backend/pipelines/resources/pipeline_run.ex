defmodule Backend.Pipelines.Resources.PipelineRun do
  @moduledoc """
  A PipelineRun represents a single execution of a pipeline.
  Uses AshStateMachine to manage status transitions.
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
    table "pipeline_runs"
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

    attribute :error_message, :string do
      public? true
    end

    attribute :input_data, :map do
      allow_nil? false
      default %{}
      public? true
      description "Initial input variables for the pipeline execution"
    end

    attribute :output_data, :map do
      default %{}
      public? true
      description "Final output data from the pipeline"
    end

    attribute :metadata, :map do
      default %{}
      public? true
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

      transition :cancel do
        from [:pending, :running]
        to :cancelled
      end
    end
  end

  relationships do
    belongs_to :pipeline, Backend.Pipelines.Resources.Pipeline do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    has_many :node_results, Backend.Pipelines.Resources.NodeResult do
      destination_attribute :pipeline_run_id
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:pipeline_id, :input_data, :metadata]
    end

    update :start do
      accept []
      change transition_state(:running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :complete do
      accept [:output_data]
      change transition_state(:completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:error_message]
      change transition_state(:failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :cancel do
      accept []
      change transition_state(:cancelled)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end
  end

  calculations do
    calculate :duration, :integer do
      calculation fn records, _context ->
        Enum.map(records, fn record ->
          if record.started_at && record.completed_at do
            DateTime.diff(record.completed_at, record.started_at, :second)
          else
            nil
          end
        end)
      end
    end

    calculate :progress_percent, :integer do
      calculation fn records, _context ->
        Enum.map(records, fn record ->
          # Load the pipeline to get total node count
          pipeline = Ash.load!(record, [:pipeline]).pipeline
          total_nodes = length(Ash.load!(pipeline, [:nodes]).nodes)

          if total_nodes == 0 do
            0
          else
            completed_nodes =
              Enum.count(Ash.load!(record, [:node_results]).node_results, fn result ->
                result.status in [:completed, :skipped]
              end)

            round(completed_nodes / total_nodes * 100)
          end
        end)
      end
    end
  end

  json_api do
    type "pipeline_run"

    routes do
      base "/pipeline_runs"

      get :read
      index :read
      post :create
      delete :destroy

      post :start, route: "/:id/start"
      post :complete, route: "/:id/complete"
      post :fail, route: "/:id/fail"
      post :cancel, route: "/:id/cancel"
    end
  end

  code_interface do
    define :create
    define :read
    define :destroy
    define :start
    define :complete, args: [:output_data]
    define :fail, args: [:error_message]
    define :cancel
  end
end
