defmodule Backend.Schemas.Client do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "clients" do
    field :name, :string
    field :description, :string
    field :homepage, :string
    field :metadata, :map
    field :brand_guidelines, :string

    has_many :campaigns, Backend.Schemas.Campaign

    timestamps()
  end

  @doc """
  Changeset for client creation and updates.
  Validates that name is required.
  """
  def changeset(client, attrs) do
    client
    |> cast(attrs, [:name, :description, :homepage, :metadata, :brand_guidelines])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end

  @doc """
  Changeset for data migration - allows setting ID manually
  """
  def migration_changeset(client, attrs) do
    client
    |> cast(attrs, [:id, :name, :brand_guidelines])
    |> validate_required([:id, :name])
    |> validate_length(:name, min: 1, max: 255)
  end
end
