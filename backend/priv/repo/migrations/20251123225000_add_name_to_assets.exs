defmodule Backend.Repo.Migrations.AddNameToAssets do
  use Ecto.Migration

  def up do
    columns = get_column_names("assets")

    unless "name" in columns do
      execute("ALTER TABLE assets ADD COLUMN name TEXT;")
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
