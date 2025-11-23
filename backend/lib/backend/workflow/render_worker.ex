defmodule Backend.Workflow.RenderWorker do
  @moduledoc """
  Worker module for parallel video rendering using Replicate API.

  Features:
  - Processes sub_jobs in parallel with configurable concurrency
  - Manages rendering lifecycle (start, poll, download)
  - Updates sub_job status and stores video blobs
  - Handles partial completion scenarios
  - Exponential backoff for API polling
  """
  require Logger
  alias Backend.Repo
  alias Backend.Schemas.{Job, SubJob}
  alias Backend.Services.ReplicateService
  import Ecto.Query

  @max_concurrency 10

  @doc """
  Processes all sub_jobs for a given job in parallel.

  ## Parameters
    - job: The Job struct or job_id
    - options: Processing options (max_concurrency, timeout)

  ## Returns
    - {:ok, results} with list of successful and failed renders
    - {:error, reason} on critical failure

  ## Example
      iex> RenderWorker.process_job(job)
      {:ok, %{successful: 5, failed: 0, results: [...]}}
  """
  def process_job(job_or_id, options \\ %{})

  def process_job(%Job{} = job, options) do
    process_job(job.id, options)
  end

  def process_job(job_id, options) when is_integer(job_id) do
    Logger.info("[RenderWorker] Starting parallel rendering for job #{job_id}")

    # Load sub_jobs that need rendering
    sub_jobs = load_pending_sub_jobs(job_id)

    if Enum.empty?(sub_jobs) do
      Logger.warning("[RenderWorker] No pending sub_jobs found for job #{job_id}")
      {:ok, %{successful: 0, failed: 0, results: []}}
    else
      Logger.info("[RenderWorker] Found #{length(sub_jobs)} sub_jobs to process")

      # Process sub_jobs in parallel
      max_concurrency = Map.get(options, :max_concurrency, @max_concurrency)
      results = process_sub_jobs_parallel(sub_jobs, max_concurrency, options)

      # Aggregate results
      successful = Enum.count(results, fn {status, _} -> status == :ok end)
      failed = Enum.count(results, fn {status, _} -> status == :error end)

      Logger.info(
        "[RenderWorker] Rendering complete for job #{job_id}: #{successful} succeeded, #{failed} failed"
      )

      {:ok, %{successful: successful, failed: failed, results: results}}
    end
  end

  @doc """
  Processes a single sub_job: starts rendering, polls for completion, downloads video.

  ## Parameters
    - sub_job: The SubJob struct
    - options: Processing options

  ## Returns
    - {:ok, sub_job} with updated video_blob on success
    - {:error, reason} on failure
  """
  def process_sub_job(%SubJob{} = sub_job, options \\ %{}) do
    Logger.info("[RenderWorker] Processing sub_job #{sub_job.id}")

    # Update status to processing
    {:ok, sub_job} = update_sub_job_status(sub_job, :processing)

    # Get scene data from job's storyboard
    scene = get_scene_for_sub_job(sub_job)

    if scene == nil do
      Logger.error("[RenderWorker] No scene data found for sub_job #{sub_job.id}")
      update_sub_job_status(sub_job, :failed)
      {:error, :no_scene_data}
    else
      # Execute rendering pipeline
      with {:ok, prediction} <- start_rendering(scene, options),
           {:ok, completed_prediction} <- poll_for_completion(prediction, options),
           {:ok, video_blob} <- download_video(completed_prediction),
           {:ok, updated_sub_job} <- store_video_blob(sub_job, video_blob, prediction["id"]) do
        Logger.info("[RenderWorker] Successfully processed sub_job #{sub_job.id}")
        {:ok, updated_sub_job}
      else
        {:error, reason} = error ->
          Logger.error(
            "[RenderWorker] Failed to process sub_job #{sub_job.id}: #{inspect(reason)}"
          )

          update_sub_job_status(sub_job, :failed)
          error
      end
    end
  end

  @doc """
  Retries failed sub_jobs for a given job.

  ## Parameters
    - job_id: The ID of the job
    - options: Retry options

  ## Returns
    - {:ok, results} with retry results
  """
  def retry_failed_sub_jobs(job_id, options \\ %{}) do
    Logger.info("[RenderWorker] Retrying failed sub_jobs for job #{job_id}")

    failed_sub_jobs =
      SubJob
      |> where([sj], sj.job_id == ^job_id and sj.status == :failed)
      |> Repo.all()

    if Enum.empty?(failed_sub_jobs) do
      Logger.info("[RenderWorker] No failed sub_jobs to retry for job #{job_id}")
      {:ok, %{successful: 0, failed: 0, results: []}}
    else
      # Reset status to pending
      Enum.each(failed_sub_jobs, fn sub_job ->
        update_sub_job_status(sub_job, :pending)
      end)

      # Process them again
      process_job(job_id, options)
    end
  end

  # Private Functions

  defp load_pending_sub_jobs(job_id) do
    SubJob
    |> where([sj], sj.job_id == ^job_id and sj.status in [:pending, :processing])
    |> Repo.all()
  end

  defp process_sub_jobs_parallel(sub_jobs, max_concurrency, options) do
    Logger.info(
      "[RenderWorker] Processing #{length(sub_jobs)} sub_jobs with max_concurrency: #{max_concurrency}"
    )

    # Use Task.async_stream for parallel processing with controlled concurrency
    sub_jobs
    |> Task.async_stream(
      fn sub_job ->
        try do
          process_sub_job(sub_job, options)
        rescue
          e ->
            Logger.error(
              "[RenderWorker] Exception processing sub_job #{sub_job.id}: #{inspect(e)}"
            )

            {:error, {:exception, Exception.message(e)}}
        end
      end,
      max_concurrency: max_concurrency,
      # 30 minutes default
      timeout: Map.get(options, :sub_job_timeout, 1_800_000),
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("[RenderWorker] Task exited: #{inspect(reason)}")
        {:error, {:task_exit, reason}}
    end)
  end

  defp update_sub_job_status(sub_job, new_status) do
    changeset = SubJob.status_changeset(sub_job, %{status: new_status})

    case Repo.update(changeset) do
      {:ok, updated_sub_job} ->
        Logger.debug("[RenderWorker] Updated sub_job #{sub_job.id} status to #{new_status}")
        {:ok, updated_sub_job}

      {:error, changeset} ->
        Logger.error(
          "[RenderWorker] Failed to update sub_job #{sub_job.id} status: #{inspect(changeset.errors)}"
        )

        {:error, :update_failed}
    end
  end

  defp get_scene_for_sub_job(sub_job) do
    # Load the job to get storyboard
    case Repo.get(Job, sub_job.job_id) do
      nil ->
        Logger.error("[RenderWorker] Job #{sub_job.job_id} not found")
        nil

      job ->
        # Extract scene data from storyboard
        # The storyboard should contain scenes array
        scenes = get_in(job.storyboard, ["scenes"]) || []

        # Find the scene for this sub_job (by index or ID)
        # For now, we'll use the position of the sub_job
        # You may need to adjust this based on your actual data structure
        sub_job_index = get_sub_job_index(job.id, sub_job.id)

        if sub_job_index != nil and sub_job_index < length(scenes) do
          Enum.at(scenes, sub_job_index)
        else
          Logger.warning(
            "[RenderWorker] Could not find scene for sub_job #{sub_job.id} at index #{sub_job_index}"
          )

          nil
        end
    end
  end

  defp get_sub_job_index(job_id, sub_job_id) do
    # Get all sub_jobs for this job ordered by insertion
    sub_jobs =
      SubJob
      |> where([sj], sj.job_id == ^job_id)
      |> order_by([sj], asc: sj.inserted_at)
      |> Repo.all()

    Enum.find_index(sub_jobs, fn sj -> sj.id == sub_job_id end)
  end

  defp start_rendering(scene, options) do
    Logger.info("[RenderWorker] Starting render for scene")

    case ReplicateService.start_render(scene, options) do
      {:ok, prediction} ->
        {:ok, prediction}

      {:error, reason} ->
        Logger.error("[RenderWorker] Failed to start render: #{inspect(reason)}")
        {:error, {:render_start_failed, reason}}
    end
  end

  defp poll_for_completion(prediction, options) do
    prediction_id = prediction.id || prediction["id"]
    Logger.info("[RenderWorker] Polling for completion of prediction #{prediction_id}")

    poll_options = %{
      max_retries: Map.get(options, :max_retries, 30),
      # 30 minutes
      timeout: Map.get(options, :timeout, 1_800_000)
    }

    case ReplicateService.poll_until_complete(prediction_id, poll_options) do
      {:ok, completed_prediction} ->
        {:ok, completed_prediction}

      {:error, reason} ->
        Logger.error(
          "[RenderWorker] Polling failed for prediction #{prediction_id}: #{inspect(reason)}"
        )

        {:error, {:polling_failed, reason}}
    end
  end

  defp download_video(completed_prediction) do
    # Extract video URL from prediction output
    video_url = extract_video_url(completed_prediction)

    if video_url == nil do
      Logger.error("[RenderWorker] No video URL found in prediction output")
      {:error, :no_video_url}
    else
      Logger.info("[RenderWorker] Downloading video from #{video_url}")

      case ReplicateService.download_video(video_url) do
        {:ok, video_blob} ->
          {:ok, video_blob}

        {:error, reason} ->
          Logger.error("[RenderWorker] Failed to download video: #{inspect(reason)}")
          {:error, {:download_failed, reason}}
      end
    end
  end

  defp extract_video_url(prediction) do
    # The output can be in different formats depending on the model
    # Common patterns:
    # - prediction["output"] as a string (URL)
    # - prediction["output"] as an array with the first element being the URL
    # - prediction["output"]["video"] as a URL

    output = prediction["output"]

    cond do
      is_binary(output) and String.starts_with?(output, "http") ->
        output

      is_list(output) and length(output) > 0 ->
        List.first(output)

      is_map(output) and Map.has_key?(output, "video") ->
        output["video"]

      true ->
        Logger.warning("[RenderWorker] Unexpected output format: #{inspect(output)}")
        nil
    end
  end

  defp store_video_blob(sub_job, video_blob, provider_id) do
    Logger.info(
      "[RenderWorker] Storing video blob for sub_job #{sub_job.id}, size: #{byte_size(video_blob)} bytes"
    )

    changeset =
      SubJob.changeset(sub_job, %{
        video_blob: video_blob,
        provider_id: provider_id,
        status: :completed
      })

    case Repo.update(changeset) do
      {:ok, updated_sub_job} ->
        Logger.info("[RenderWorker] Successfully stored video blob for sub_job #{sub_job.id}")
        {:ok, updated_sub_job}

      {:error, changeset} ->
        Logger.error("[RenderWorker] Failed to store video blob: #{inspect(changeset.errors)}")
        {:error, :storage_failed}
    end
  end
end
