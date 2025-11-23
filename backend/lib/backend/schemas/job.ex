defmodule Backend.Schemas.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @job_types [:image_pairs, :property_photos]
  @job_statuses [:pending, :approved, :processing, :completed, :failed]

  schema "jobs" do
    field :type, Ecto.Enum, values: @job_types
    field :status, Ecto.Enum, values: @job_statuses, default: :pending
    field :parameters, :map
    field :storyboard, :map
    field :progress, :map
    field :result, :binary
    field :audio_blob, :binary

    has_many :sub_jobs, Backend.Schemas.SubJob

    timestamps()
  end

  @doc """
  Returns the list of valid job types.
  """
  def job_types, do: @job_types

  @doc """
  Returns the list of valid job statuses.
  """
  def job_statuses, do: @job_statuses

  @doc """
  Changeset for job creation and updates.
  Validates type and status enums.
  """
  def changeset(job, attrs) do
    job
    |> cast(attrs, [:type, :status, :parameters, :storyboard, :progress, :result, :audio_blob])
    |> validate_required([:type])
    |> validate_inclusion(:type, @job_types)
    |> validate_inclusion(:status, @job_statuses)
  end

  @doc """
  Changeset for updating job status.
  """
  def status_changeset(job, attrs) do
    job
    |> cast(attrs, [:status, :progress])
    |> validate_required([:status])
    |> validate_inclusion(:status, @job_statuses)
  end

  @doc """
  Changeset for updating job result.
  """
  def result_changeset(job, attrs) do
    job
    |> cast(attrs, [:result, :status])
    |> validate_required([:result])
  end

  @doc """
  Changeset for updating job audio.
  """
  def audio_changeset(job, attrs) do
    job
    |> cast(attrs, [:audio_blob, :progress])
  end
end
