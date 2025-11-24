defmodule Backend.Repo.Migrations.AddVideoNameAndCostToJobs do
  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :video_name, :string
      add :estimated_cost, :float
    end

    execute("""
    UPDATE jobs
    SET estimated_cost = COALESCE(estimated_cost, json_extract(parameters, '$.estimated_cost'))
    """)

    execute("""
    UPDATE jobs
    SET video_name = COALESCE(
        video_name,
        TRIM(COALESCE(json_extract(parameters, '$.campaign_name'), 'Video'))
        || ' ' || id
      )
    """)
  end

  def down do
    alter table(:jobs) do
      remove :estimated_cost
      remove :video_name
    end
  end
end
