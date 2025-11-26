defmodule Backend.Repo.Migrations.AddVideoNameAndCostToJobs do
  use Ecto.Migration

  def up do
    columns = get_column_names("jobs")

    unless "video_name" in columns do
      execute("ALTER TABLE jobs ADD COLUMN video_name TEXT;")
    end

    unless "estimated_cost" in columns do
      execute("ALTER TABLE jobs ADD COLUMN estimated_cost REAL;")
    end

    # Populate from parameters if not already set (idempotent)
    execute("""
    UPDATE jobs
    SET estimated_cost = COALESCE(estimated_cost, json_extract(parameters, '$.estimated_cost'))
    WHERE estimated_cost IS NULL
    """)

    execute("""
    UPDATE jobs
    SET video_name = COALESCE(
        video_name,
        TRIM(COALESCE(json_extract(parameters, '$.campaign_name'), 'Video'))
        || ' ' || id
      )
    WHERE video_name IS NULL
    """)
  end

  def down do
    :ok
  end

  defp get_column_names(table) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table});")
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end
end
