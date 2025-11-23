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

    belongs_to :campaign, Backend.Schemas.Campaign

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
    |> cast(attrs, [:type, :blob_data, :metadata, :source_url, :campaign_id])
    |> validate_required([:type, :campaign_id])
    |> validate_inclusion(:type, @asset_types)
    |> validate_asset_source()
    |> foreign_key_constraint(:campaign_id)
  end

  @doc """
  Changeset for data migration - allows setting ID manually
  """
  def migration_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:id, :type, :blob_data, :metadata, :source_url, :campaign_id])
    |> validate_required([:id, :type, :campaign_id])
    |> validate_inclusion(:type, @asset_types)
    |> validate_asset_source()
    |> foreign_key_constraint(:campaign_id)
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
end
