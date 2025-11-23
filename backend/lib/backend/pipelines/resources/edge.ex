defmodule Backend.Pipelines.Resources.Edge do
  @moduledoc """
  An Edge represents a connection between two nodes in a pipeline, defining data flow.
  """

  use Ash.Resource,
    domain: Backend.Pipelines.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  sqlite do
    repo Backend.Repo
    table "edges"
  end

  attributes do
    uuid_primary_key :id

    attribute :source_handle, :string do
      public? true
      description "Optional handle for multi-output nodes"
    end

    attribute :target_handle, :string do
      public? true
      description "Optional handle for multi-input nodes"
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :pipeline, Backend.Pipelines.Resources.Pipeline do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :source_node, Backend.Pipelines.Resources.Node do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :target_node, Backend.Pipelines.Resources.Node do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  validations do
    validate fn changeset, _context ->
      pipeline_id = Ash.Changeset.get_attribute(changeset, :pipeline_id)
      source_node_id = Ash.Changeset.get_attribute(changeset, :source_node_id)
      target_node_id = Ash.Changeset.get_attribute(changeset, :target_node_id)

      cond do
        source_node_id == target_node_id ->
          {:error, field: :target_node_id, message: "Cannot connect a node to itself"}

        true ->
          # Validate nodes are in the same pipeline
          with {:ok, source} <-
                 Backend.Pipelines.Resources.Node.read(source_node_id),
               {:ok, target} <-
                 Backend.Pipelines.Resources.Node.read(target_node_id) do
            if source.pipeline_id == pipeline_id and target.pipeline_id == pipeline_id do
              # TODO: Add cycle detection here
              :ok
            else
              {:error,
               field: :pipeline_id, message: "Source and target nodes must be in the same pipeline"}
            end
          else
            _ -> {:error, field: :source_node_id, message: "Invalid node references"}
          end
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:pipeline_id, :source_node_id, :target_node_id, :source_handle, :target_handle, :metadata]
    end

    update :update do
      primary? true
      accept [:source_handle, :target_handle, :metadata]
    end
  end

  identities do
    identity :unique_edge, [:source_node_id, :target_node_id, :source_handle, :target_handle]
  end

  json_api do
    type "edge"

    routes do
      base "/edges"

      get :read
      index :read
      post :create
      patch :update
      delete :destroy
    end
  end

  code_interface do
    define :create
    define :read
    define :update
    define :destroy
  end
end
