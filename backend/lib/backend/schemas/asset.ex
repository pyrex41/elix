defmodule Backend.Schemas.Asset do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @asset_types [:image, :video, :audio]

  schema "assets" do
    field :type, Ecto.Enum, values: @asset_types
    field :blob_data, :binary
    field :metadata, :map
    field :source_url, :string
    field :description, :string
    field :name, :string
    field :tags, {:array, :string}
    field :width, :integer
    field :height, :integer

    belongs_to :campaign, Backend.Schemas.Campaign
    belongs_to :client, Backend.Schemas.Client

    timestamps()
  end

  @doc """
  Returns the list of valid asset types.
  """
  def asset_types, do: @asset_types

  @doc """
  Changeset for asset creation and updates.
  Validates type enum and ensures either blob_data or source_url is present.
  """
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :type,
      :blob_data,
      :metadata,
      :source_url,
      :campaign_id,
      :client_id,
      :description,
      :tags,
      :name,
      :width,
      :height
    ])
    |> validate_required([:type])
    |> validate_inclusion(:type, @asset_types)
    |> validate_asset_source()
    |> validate_tags()
    |> validate_campaign_or_client()
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:client_id)
  end

  @doc """
  Changeset for data migration - allows setting ID manually
  """
  def migration_changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :id,
      :type,
      :blob_data,
      :metadata,
      :source_url,
      :campaign_id,
      :client_id,
      :description,
      :tags,
      :name,
      :width,
      :height
    ])
    |> validate_required([:id, :type])
    |> validate_inclusion(:type, @asset_types)
    |> validate_asset_source()
    |> validate_tags()
    |> validate_campaign_or_client()
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:client_id)
  end

  # Private function to validate that either blob_data or source_url is present
  defp validate_asset_source(changeset) do
    blob_data = get_field(changeset, :blob_data)
    source_url = get_field(changeset, :source_url)

    cond do
      blob_data != nil -> changeset
      source_url != nil and source_url != "" -> changeset
      true -> add_error(changeset, :base, "either blob_data or source_url must be present")
    end
  end

  defp validate_campaign_or_client(changeset) do
    campaign_id = get_field(changeset, :campaign_id)
    client_id = get_field(changeset, :client_id)

    if is_nil(campaign_id) and is_nil(client_id) do
      changeset
      |> add_error(:campaign_id, "must include campaign_id or client_id")
      |> add_error(:client_id, "must include campaign_id or client_id")
    else
      changeset
    end
  end

  defp validate_tags(changeset) do
    case get_field(changeset, :tags) do
      nil ->
        changeset

      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1) do
          changeset
        else
          add_error(changeset, :tags, "must be an array of strings")
        end

      _ ->
        add_error(changeset, :tags, "must be an array of strings")
    end
  end
end
