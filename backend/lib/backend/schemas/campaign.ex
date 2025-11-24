defmodule Backend.Schemas.Campaign do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "campaigns" do
    field :name, :string
    field :brief, :string
    field :goal, :string
    field :status, :string
    field :product_url, :string
    field :metadata, :map

    belongs_to :client, Backend.Schemas.Client
    has_many :assets, Backend.Schemas.Asset

    timestamps()
  end

  @doc """
  Changeset for campaign creation and updates.
  Only the name and client reference are required; brief is optional.
  """
  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:name, :brief, :goal, :status, :product_url, :metadata, :client_id])
    |> validate_required([:name, :client_id])
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:client_id)
  end

  @doc """
  Changeset for data migration - allows setting ID manually
  """
  def migration_changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:id, :name, :brief, :goal, :status, :product_url, :metadata, :client_id])
    |> validate_required([:id, :name, :client_id])
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:client_id)
  end
end
