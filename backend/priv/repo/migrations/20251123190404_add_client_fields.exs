defmodule Backend.Repo.Migrations.AddClientFields do
  use Ecto.Migration

  def up do
    # Check if columns already exist before adding
    # SQLite doesn't have ADD COLUMN IF NOT EXISTS, so we check pragma
    columns = get_column_names("clients")

    unless "description" in columns do
      execute("ALTER TABLE clients ADD COLUMN description TEXT;")
    end

    unless "homepage" in columns do
      execute("ALTER TABLE clients ADD COLUMN homepage TEXT;")
    end

    unless "metadata" in columns do
      execute("ALTER TABLE clients ADD COLUMN metadata TEXT;")
    end
  end

  def down do
    # SQLite doesn't support DROP COLUMN easily, so we'd need to recreate table
    # For safety, we leave columns in place
    :ok
  end

  defp get_column_names(table) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table});")
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end
end
