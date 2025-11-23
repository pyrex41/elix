defmodule Backend.Schemas.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :password_hash, :string
    field :api_key_hash, :string

    timestamps()
  end

  @doc """
  Changeset for user creation and updates.
  Validates email format and ensures required fields are present.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password_hash, :api_key_hash])
    |> validate_required([:username, :email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/,
      message: "must be a valid email address"
    )
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end

  @doc """
  Changeset for password updates.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password_hash])
    |> validate_required([:password_hash])
  end

  @doc """
  Changeset for API key updates.
  """
  def api_key_changeset(user, attrs) do
    user
    |> cast(attrs, [:api_key_hash])
    |> validate_required([:api_key_hash])
  end
end
