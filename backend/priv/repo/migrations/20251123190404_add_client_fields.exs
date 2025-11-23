defmodule Backend.Repo.Migrations.AddClientFields do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add :description, :text
      add :homepage, :string
      add :metadata, :map
    end
  end
end
