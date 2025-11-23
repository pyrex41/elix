defmodule Backend.Repo.Migrations.AddCampaignFields do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :goal, :text
      add :status, :string
      add :product_url, :string
      add :metadata, :map
    end
  end
end
