defmodule Backend.Schemas.SubJob do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sub_job_statuses [:pending, :processing, :completed, :failed]

  schema "sub_jobs" do
    field :provider_id, :string
    field :status, Ecto.Enum, values: @sub_job_statuses, default: :pending
    field :video_blob, :binary

    belongs_to :job, Backend.Schemas.Job, type: :integer

    timestamps()
  end

  @doc """
  Returns the list of valid sub_job statuses.
  """
  def sub_job_statuses, do: @sub_job_statuses

  @doc """
  Changeset for sub_job creation and updates.
  Validates status enum and job association.
  """
  def changeset(sub_job, attrs) do
    sub_job
    |> cast(attrs, [:provider_id, :status, :video_blob, :job_id])
    |> validate_required([:job_id])
    |> validate_inclusion(:status, @sub_job_statuses)
    |> foreign_key_constraint(:job_id)
  end

  @doc """
  Changeset for updating sub_job status.
  """
  def status_changeset(sub_job, attrs) do
    sub_job
    |> cast(attrs, [:status, :provider_id])
    |> validate_required([:status])
    |> validate_inclusion(:status, @sub_job_statuses)
  end

  @doc """
  Changeset for updating sub_job video blob.
  """
  def video_changeset(sub_job, attrs) do
    sub_job
    |> cast(attrs, [:video_blob, :status])
    |> validate_required([:video_blob])
  end
end
