defmodule Backend.Pipelines.Resources.Node do
  @moduledoc """
  A Node represents a single step in a pipeline.
  Each node has a type (text, http_request, llm, etc.) and configuration specific to that type.
  """

  use Ash.Resource,
    domain: Backend.Pipelines.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  sqlite do
    repo Backend.Repo
    table "nodes"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :type, :atom do
      allow_nil? false
      constraints one_of: [:text, :http_request, :llm, :condition, :transform]
      public? true
    end

    attribute :config, :map do
      allow_nil? false
      default %{}
      public? true
      description """
      Node-specific configuration:
      - text: {content: "template string"}
      - http_request: {url, method, headers, body}
      - llm: {provider, model, system_prompt, user_prompt, temperature, max_tokens}
      """
    end

    attribute :position, :map do
      default %{"x" => 0, "y" => 0}
      public? true
      description "UI coordinates for visual pipeline editor"
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

    has_many :outgoing_edges, Backend.Pipelines.Resources.Edge do
      destination_attribute :source_node_id
      public? true
    end

    has_many :incoming_edges, Backend.Pipelines.Resources.Edge do
      destination_attribute :target_node_id
      public? true
    end

    has_many :results, Backend.Pipelines.Resources.NodeResult do
      destination_attribute :node_id
      public? true
    end
  end

  validations do
    validate fn changeset, _context ->
      type = Ash.Changeset.get_attribute(changeset, :type)
      config = Ash.Changeset.get_attribute(changeset, :config)

      case validate_config_for_type(type, config) do
        :ok -> :ok
        {:error, message} -> {:error, field: :config, message: message}
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:pipeline_id, :name, :type, :config, :position, :metadata]
    end

    update :update do
      primary? true
      accept [:name, :type, :config, :position, :metadata]
    end
  end

  calculations do
    calculate :dependency_count, :integer, expr(count(incoming_edges))
    calculate :dependent_count, :integer, expr(count(outgoing_edges))
  end

  json_api do
    type "node"

    routes do
      base "/nodes"

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

  # Private helper for config validation
  defp validate_config_for_type(:text, config) do
    if Map.has_key?(config, "content") or Map.has_key?(config, :content) do
      :ok
    else
      {:error, "Text node requires 'content' field in config"}
    end
  end

  defp validate_config_for_type(:http_request, config) do
    required = ["url", "method"]

    missing =
      Enum.filter(required, fn key ->
        not (Map.has_key?(config, key) or Map.has_key?(config, String.to_atom(key)))
      end)

    if missing == [] do
      :ok
    else
      {:error, "HTTP request node requires: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_config_for_type(:llm, config) do
    required = ["model", "user_prompt"]

    missing =
      Enum.filter(required, fn key ->
        not (Map.has_key?(config, key) or Map.has_key?(config, String.to_atom(key)))
      end)

    if missing == [] do
      :ok
    else
      {:error, "LLM node requires: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_config_for_type(_type, _config), do: :ok
end
