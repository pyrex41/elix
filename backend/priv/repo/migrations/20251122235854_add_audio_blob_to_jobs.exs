defmodule Backend.Repo.Migrations.AddAudioBlobToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :audio_blob, :binary
    end
  end
end
