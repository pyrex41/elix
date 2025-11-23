defmodule Backend.Workflow.Coordinator do
  @moduledoc """
  Singleton GenServer that coordinates job workflow orchestration.

  Responsibilities:
  - Subscribe to Phoenix.PubSub for job events
  - Handle job approval messages
  - Track job states (pending, approved, processing, completed)
  - Spawn and manage job processing tasks
  - Resume interrupted workflows on startup
  """
  use GenServer
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.{Job, SubJob}
  alias Backend.Workflow.StitchWorker
  import Ecto.Query

  @pubsub_name Backend.PubSub
  @topics %{
    created: "jobs:created",
    approved: "jobs:approved",
    completed: "jobs:completed"
  }

  # Client API

  @doc """
  Starts the Workflow Coordinator GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Approves a job and triggers processing.
  """
  def approve_job(job_id) do
    GenServer.cast(__MODULE__, {:approve_job, job_id})
  end

  @doc """
  Updates job progress.
  """
  def update_progress(job_id, progress_data) do
    GenServer.cast(__MODULE__, {:update_progress, job_id, progress_data})
  end

  @doc """
  Marks a job as completed.
  """
  def complete_job(job_id, result) do
    GenServer.cast(__MODULE__, {:complete_job, job_id, result})
  end

  @doc """
  Marks a job as failed.
  """
  def fail_job(job_id, reason) do
    GenServer.cast(__MODULE__, {:fail_job, job_id, reason})
  end

  @doc """
  Notifies coordinator of a scene update.
  """
  def scene_updated(job_id, scene_id, status) do
    GenServer.cast(__MODULE__, {:scene_updated, job_id, scene_id, status})
  end

  @doc """
  Notifies coordinator that a sub_job has completed rendering.
  Checks if all sub_jobs are done and triggers stitching if so.
  """
  def sub_job_completed(job_id, sub_job_id) do
    GenServer.cast(__MODULE__, {:sub_job_completed, job_id, sub_job_id})
  end

  @doc """
  Notifies coordinator to regenerate a scene.
  """
  def scene_regenerate(job_id, scene_id) do
    GenServer.cast(__MODULE__, {:scene_regenerate, job_id, scene_id})
  end

  @doc """
  Notifies coordinator of a scene deletion.
  """
  def scene_deleted(job_id, scene_id) do
    GenServer.cast(__MODULE__, {:scene_deleted, job_id, scene_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("[Workflow.Coordinator] Starting Workflow Coordinator")

    # Subscribe to PubSub topics
    Phoenix.PubSub.subscribe(@pubsub_name, @topics.created)
    Phoenix.PubSub.subscribe(@pubsub_name, @topics.approved)
    Phoenix.PubSub.subscribe(@pubsub_name, @topics.completed)

    # Initialize state with job tracking
    state = %{
      active_jobs: %{},
      processing_tasks: %{}
    }

    # Perform startup recovery
    send(self(), :recover_interrupted_jobs)

    {:ok, state}
  end

  @impl true
  def handle_info(:recover_interrupted_jobs, state) do
    Logger.info("[Workflow.Coordinator] Recovering interrupted jobs")

    # Query for jobs that were in 'processing' state
    processing_jobs =
      Job
      |> where([j], j.status == :processing)
      |> Repo.all()

    # Resume each interrupted job
    Enum.each(processing_jobs, fn job ->
      Logger.warning("[Workflow.Coordinator] Resuming interrupted job #{job.id}")
      resume_job_processing(job)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:job_created, job_id}, state) do
    Logger.info("[Workflow.Coordinator] Job created: #{job_id}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:job_approved, job_id}, state) do
    Logger.info("[Workflow.Coordinator] Job approved via PubSub: #{job_id}")
    # Handle approval from PubSub
    new_state = handle_job_approval(job_id, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:job_completed, job_id}, state) do
    Logger.info("[Workflow.Coordinator] Job completed: #{job_id}")

    # Clean up active job tracking
    new_state =
      state
      |> Map.update!(:active_jobs, &Map.delete(&1, job_id))
      |> Map.update!(:processing_tasks, &Map.delete(&1, job_id))

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:task_completed, job_id, result}, state) do
    Logger.info("[Workflow.Coordinator] Task completed for job #{job_id}")

    # Update job status to completed
    case Repo.get(Job, job_id) do
      nil ->
        Logger.error("[Workflow.Coordinator] Job #{job_id} not found")
        {:noreply, state}

      job ->
        changeset =
          Job.changeset(job, %{
            status: :completed,
            result: result,
            progress: %{percentage: 100, stage: "completed"}
          })

        case Repo.update(changeset) do
          {:ok, _updated_job} ->
            Logger.info("[Workflow.Coordinator] Job #{job_id} marked as completed")

            # Broadcast completion event
            Phoenix.PubSub.broadcast(
              @pubsub_name,
              @topics.completed,
              {:job_completed, job_id}
            )

            # Clean up state
            new_state =
              state
              |> Map.update!(:active_jobs, &Map.delete(&1, job_id))
              |> Map.update!(:processing_tasks, &Map.delete(&1, job_id))

            {:noreply, new_state}

          {:error, changeset} ->
            Logger.error(
              "[Workflow.Coordinator] Failed to update job #{job_id}: #{inspect(changeset.errors)}"
            )

            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:task_failed, job_id, reason}, state) do
    Logger.error("[Workflow.Coordinator] Task failed for job #{job_id}: #{inspect(reason)}")

    # Update job status to failed
    case Repo.get(Job, job_id) do
      nil ->
        Logger.error("[Workflow.Coordinator] Job #{job_id} not found")
        {:noreply, state}

      job ->
        changeset =
          Job.changeset(job, %{
            status: :failed,
            progress: %{percentage: 0, stage: "failed", error: inspect(reason)}
          })

        case Repo.update(changeset) do
          {:ok, _updated_job} ->
            Logger.info("[Workflow.Coordinator] Job #{job_id} marked as failed")

            # Clean up state
            new_state =
              state
              |> Map.update!(:active_jobs, &Map.delete(&1, job_id))
              |> Map.update!(:processing_tasks, &Map.delete(&1, job_id))

            {:noreply, new_state}

          {:error, changeset} ->
            Logger.error(
              "[Workflow.Coordinator] Failed to update job #{job_id}: #{inspect(changeset.errors)}"
            )

            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:approve_job, job_id}, state) do
    Logger.info("[Workflow.Coordinator] Approving job #{job_id}")
    new_state = handle_job_approval(job_id, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_progress, job_id, progress_data}, state) do
    Logger.debug(
      "[Workflow.Coordinator] Updating progress for job #{job_id}: #{inspect(progress_data)}"
    )

    try do
      case Repo.get(Job, job_id) do
        nil ->
          Logger.error("[Workflow.Coordinator] Job #{job_id} not found")
          {:noreply, state}

        job ->
          changeset = Job.changeset(job, %{progress: progress_data})

          case Repo.update(changeset) do
            {:ok, _updated_job} ->
              {:noreply, state}

            {:error, changeset} ->
              Logger.error(
                "[Workflow.Coordinator] Failed to update progress for job #{job_id}: #{inspect(changeset.errors)}"
              )

              {:noreply, state}
          end
      end
    rescue
      e ->
        Logger.error("[Workflow.Coordinator] Error updating progress: #{inspect(e)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:complete_job, job_id, result}, state) do
    Logger.info("[Workflow.Coordinator] Completing job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        Logger.error("[Workflow.Coordinator] Job #{job_id} not found")
        {:noreply, state}

      job ->
        changeset =
          Job.changeset(job, %{
            status: :completed,
            result: result,
            progress: %{percentage: 100, stage: "completed"}
          })

        case Repo.update(changeset) do
          {:ok, _updated_job} ->
            # Broadcast completion event
            Phoenix.PubSub.broadcast(
              @pubsub_name,
              @topics.completed,
              {:job_completed, job_id}
            )

            # Clean up state
            new_state =
              state
              |> Map.update!(:active_jobs, &Map.delete(&1, job_id))
              |> Map.update!(:processing_tasks, &Map.delete(&1, job_id))

            {:noreply, new_state}

          {:error, changeset} ->
            Logger.error(
              "[Workflow.Coordinator] Failed to complete job #{job_id}: #{inspect(changeset.errors)}"
            )

            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:fail_job, job_id, reason}, state) do
    Logger.error("[Workflow.Coordinator] Failing job #{job_id}: #{inspect(reason)}")

    case Repo.get(Job, job_id) do
      nil ->
        Logger.error("[Workflow.Coordinator] Job #{job_id} not found")
        {:noreply, state}

      job ->
        changeset =
          Job.changeset(job, %{
            status: :failed,
            progress: %{percentage: 0, stage: "failed", error: inspect(reason)}
          })

        case Repo.update(changeset) do
          {:ok, _updated_job} ->
            # Clean up state
            new_state =
              state
              |> Map.update!(:active_jobs, &Map.delete(&1, job_id))
              |> Map.update!(:processing_tasks, &Map.delete(&1, job_id))

            {:noreply, new_state}

          {:error, changeset} ->
            Logger.error(
              "[Workflow.Coordinator] Failed to fail job #{job_id}: #{inspect(changeset.errors)}"
            )

            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:scene_updated, job_id, scene_id, status}, state) do
    Logger.info(
      "[Workflow.Coordinator] Scene #{scene_id} updated for job #{job_id} with status: #{status}"
    )

    # Log the scene update event
    # Future: Could trigger webhooks, notifications, or workflow actions here
    {:noreply, state}
  end

  @impl true
  def handle_cast({:scene_regenerate, job_id, scene_id}, state) do
    Logger.info(
      "[Workflow.Coordinator] Scene #{scene_id} marked for regeneration in job #{job_id}"
    )

    # Future: Could spawn a task to re-process this specific scene
    # For now, just log the event
    {:noreply, state}
  end

  @impl true
  def handle_cast({:scene_deleted, job_id, scene_id}, state) do
    Logger.info("[Workflow.Coordinator] Scene #{scene_id} deleted from job #{job_id}")

    # Log the deletion event
    # Future: Could trigger cleanup tasks or workflow adjustments
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sub_job_completed, job_id, sub_job_id}, state) do
    Logger.info("[Workflow.Coordinator] Sub_job #{sub_job_id} completed for job #{job_id}")

    # Check if all sub_jobs are completed for this job
    case check_all_sub_jobs_completed(job_id) do
      {:ok, :all_completed} ->
        Logger.info(
          "[Workflow.Coordinator] All sub_jobs completed for job #{job_id}, triggering stitching"
        )

        # Update progress to indicate stitching is starting
        update_progress(job_id, %{
          percentage: 75,
          stage: "all_renders_complete"
        })

        # Spawn async task for stitching
        Task.start(fn ->
          case StitchWorker.stitch_job(job_id) do
            {:ok, _result} ->
              Logger.info("[Workflow.Coordinator] Stitching completed for job #{job_id}")

            {:error, reason} ->
              Logger.error(
                "[Workflow.Coordinator] Stitching failed for job #{job_id}: #{inspect(reason)}"
              )
          end
        end)

        {:noreply, state}

      {:ok, :pending} ->
        Logger.debug("[Workflow.Coordinator] Some sub_jobs still pending for job #{job_id}")
        {:noreply, state}

      {:error, reason} ->
        Logger.error(
          "[Workflow.Coordinator] Error checking sub_jobs for job #{job_id}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  # Private Functions

  defp handle_job_approval(job_id, state) do
    case Repo.get(Job, job_id) do
      nil ->
        Logger.error("[Workflow.Coordinator] Job #{job_id} not found")
        state

      job ->
        # Update job status to approved atomically
        changeset =
          Job.changeset(job, %{
            status: :approved,
            progress: %{percentage: 0, stage: "approved"}
          })

        case Repo.update(changeset) do
          {:ok, updated_job} ->
            Logger.info("[Workflow.Coordinator] Job #{job_id} approved, starting processing")

            # Broadcast approval event
            Phoenix.PubSub.broadcast(
              @pubsub_name,
              @topics.approved,
              {:job_approved, job_id}
            )

            # Spawn job processing task
            spawn_job_processing(updated_job, state)

          {:error, changeset} ->
            Logger.error(
              "[Workflow.Coordinator] Failed to approve job #{job_id}: #{inspect(changeset.errors)}"
            )

            state
        end
    end
  end

  defp spawn_job_processing(job, state) do
    Logger.info("[Workflow.Coordinator] Spawning processing task for job #{job.id}")

    # Update job status to processing
    changeset =
      Job.changeset(job, %{
        status: :processing,
        progress: %{percentage: 5, stage: "initializing"}
      })

    case Repo.update(changeset) do
      {:ok, _updated_job} ->
        # Spawn async task for job processing
        task = Task.async(fn -> process_job(job) end)

        # Track the task and job
        new_state =
          state
          |> Map.update!(:active_jobs, &Map.put(&1, job.id, job))
          |> Map.update!(:processing_tasks, &Map.put(&1, job.id, task))

        # Monitor the task
        spawn_task_monitor(task, job.id)

        new_state

      {:error, changeset} ->
        Logger.error(
          "[Workflow.Coordinator] Failed to start processing job #{job.id}: #{inspect(changeset.errors)}"
        )

        state
    end
  end

  defp resume_job_processing(job) do
    Logger.info("[Workflow.Coordinator] Resuming job #{job.id}")

    # Reset progress and continue processing
    changeset =
      Job.changeset(job, %{
        progress: %{percentage: 5, stage: "resuming"}
      })

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        # Spawn async task for job processing
        Task.start(fn -> process_job(updated_job) end)

      {:error, changeset} ->
        Logger.error(
          "[Workflow.Coordinator] Failed to resume job #{job.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp spawn_task_monitor(task, job_id) do
    parent = self()

    spawn(fn ->
      case Task.await(task, :infinity) do
        {:ok, result} ->
          send(parent, {:task_completed, job_id, result})

        {:error, reason} ->
          send(parent, {:task_failed, job_id, reason})
      end
    end)
  end

  defp process_job(job) do
    Logger.info("[Workflow.Coordinator] Processing job #{job.id} of type #{job.type}")

    try do
      # Update progress to indicate rendering has started
      update_progress(job.id, %{percentage: 10, stage: "starting_render"})

      # Process rendering through RenderWorker
      case Backend.Workflow.RenderWorker.process_job(job) do
        {:ok, %{successful: successful, failed: failed, results: _results}} ->
          total = successful + failed

          if failed == 0 do
            Logger.info(
              "[Workflow.Coordinator] All #{total} sub_jobs completed successfully for job #{job.id}"
            )

            update_progress(job.id, %{
              percentage: 75,
              stage: "rendering_complete",
              successful: successful,
              failed: 0
            })

            # Trigger video stitching
            Logger.info("[Workflow.Coordinator] Starting video stitching for job #{job.id}")

            case StitchWorker.stitch_job(job.id) do
              {:ok, _result} ->
                {:ok,
                 "Job processing completed: #{successful}/#{total} scenes rendered and stitched successfully"}

              {:error, stitch_reason} ->
                Logger.error(
                  "[Workflow.Coordinator] Stitching failed for job #{job.id}: #{inspect(stitch_reason)}"
                )

                {:error, "Rendering succeeded but stitching failed: #{inspect(stitch_reason)}"}
            end
          else
            Logger.warning(
              "[Workflow.Coordinator] Job #{job.id} completed with failures: #{successful} succeeded, #{failed} failed"
            )

            # Attempt partial stitching with successful sub_jobs
            if successful > 0 do
              Logger.info("[Workflow.Coordinator] Attempting partial stitching for job #{job.id}")

              update_progress(job.id, %{
                percentage: 75,
                stage: "partial_rendering_complete",
                successful: successful,
                failed: failed
              })

              case StitchWorker.partial_stitch(job.id, %{skip_failed: true}) do
                {:ok, _result} ->
                  {:ok,
                   "Job processing completed with partial success: #{successful}/#{total} scenes rendered and stitched"}

                {:error, stitch_reason} ->
                  Logger.error(
                    "[Workflow.Coordinator] Partial stitching failed for job #{job.id}: #{inspect(stitch_reason)}"
                  )

                  update_progress(job.id, %{
                    percentage: 90,
                    stage: "completed_with_failures",
                    successful: successful,
                    failed: failed
                  })

                  {:ok,
                   "Job processing completed with failures: #{successful}/#{total} scenes rendered, stitching failed"}
              end
            else
              update_progress(job.id, %{
                percentage: 0,
                stage: "all_renders_failed",
                successful: 0,
                failed: failed
              })

              {:error, "All rendering attempts failed"}
            end
          end

        {:error, reason} ->
          Logger.error(
            "[Workflow.Coordinator] RenderWorker failed for job #{job.id}: #{inspect(reason)}"
          )

          {:error, "Rendering failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("[Workflow.Coordinator] Error processing job #{job.id}: #{inspect(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp check_all_sub_jobs_completed(job_id) do
    try do
      # Get all sub_jobs for this job
      sub_jobs =
        SubJob
        |> where([s], s.job_id == ^job_id)
        |> Repo.all()

      if Enum.empty?(sub_jobs) do
        # No sub_jobs yet
        {:ok, :pending}
      else
        # Check if all are completed
        all_completed = Enum.all?(sub_jobs, &(&1.status == :completed))

        if all_completed do
          {:ok, :all_completed}
        else
          {:ok, :pending}
        end
      end
    rescue
      e ->
        Logger.error("[Workflow.Coordinator] Error checking sub_jobs: #{inspect(e)}")
        {:error, :check_failed}
    end
  end
end
