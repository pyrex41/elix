defmodule Backend.Pipelines.Resources.Pipeline do
  @moduledoc """
  A Pipeline is a container for a collection of connected nodes that form a workflow.
  """

  use Ash.Resource,
    domain: Backend.Pipelines.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  sqlite do
    repo Backend.Repo
    table "pipelines"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :draft
      constraints one_of: [:draft, :active, :archived]
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :nodes, Backend.Pipelines.Resources.Node do
      destination_attribute :pipeline_id
      public? true
    end

    has_many :edges, Backend.Pipelines.Resources.Edge do
      destination_attribute :pipeline_id
      public? true
    end

    has_many :runs, Backend.Pipelines.Resources.PipelineRun do
      destination_attribute :pipeline_id
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :status, :metadata]
    end

    update :update do
      primary? true
      accept [:name, :description, :status, :metadata]
    end

    update :publish do
      accept []
      change set_attribute(:status, :active)
    end

    update :archive do
      accept []
      change set_attribute(:status, :archived)
    end

    action :execute, :map do
      argument :input_data, :map, allow_nil? false

      run fn input, _context ->
        pipeline = input.resource

        # Create a new pipeline run
        {:ok, run} =
          Backend.Pipelines.Resources.PipelineRun
          |> Ash.Changeset.for_create(:create, %{
            pipeline_id: pipeline.id,
            input_data: input.arguments.input_data
          })
          |> Ash.create()

        # Enqueue the pipeline coordinator job
        %{pipeline_run_id: run.id}
        |> Backend.Pipelines.Jobs.PipelineCoordinator.new()
        |> Oban.insert()

        {:ok, %{run_id: run.id, status: "queued"}}
      end
    end
  end

  calculations do
    calculate :node_count, :integer, expr(count(nodes))
    calculate :run_count, :integer, expr(count(runs))
  end

  json_api do
    type "pipeline"

    routes do
      base "/pipelines"

      get :read
      index :read
      post :create
      patch :update
      delete :destroy

      post :execute, route: "/:id/execute"
    end
  end

  code_interface do
    define :create
    define :read
    define :update
    define :destroy
    define :publish
    define :archive
    define :execute, args: [:input_data]
  end
end
