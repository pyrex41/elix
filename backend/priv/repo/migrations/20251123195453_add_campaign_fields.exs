defmodule Backend.Repo.Migrations.AddCampaignFields do
  use Ecto.Migration

  def up do
    columns = get_column_names("campaigns")

    unless "goal" in columns do
      execute("ALTER TABLE campaigns ADD COLUMN goal TEXT;")
    end

    unless "status" in columns do
      execute("ALTER TABLE campaigns ADD COLUMN status TEXT;")
    end

    unless "product_url" in columns do
      execute("ALTER TABLE campaigns ADD COLUMN product_url TEXT;")
    end

    unless "metadata" in columns do
      execute("ALTER TABLE campaigns ADD COLUMN metadata TEXT;")
    end
  end

  def down do
    :ok
  end

  defp get_column_names(table) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table});")
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end
end
