defmodule Backend.Workflow.StitchWorker do
  @moduledoc """
  Worker module for stitching rendered videos into a final output.

  This module is triggered after all sub_jobs complete rendering.
  It coordinates the video stitching workflow:
  1. Creates temporary directory
  2. Extracts video blobs to files
  3. Generates FFmpeg concat file
  4. Executes FFmpeg stitching
  5. Stores result in job.result
  6. Cleans up temporary files
  7. Updates job status
  """

  require Logger
  alias Backend.Repo
  alias Backend.Schemas.{Job, SubJob}
  alias Backend.Services.FfmpegService
  alias Backend.Workflow.Coordinator
  import Ecto.Query

  @tmp_base_dir "/tmp"
  @min_free_space_mb 100

  @doc """
  Performs the complete video stitching workflow for a job.

  ## Parameters
  - `job_id`: The ID of the job to stitch videos for

  ## Returns
  - `{:ok, result}` - Successfully stitched and stored video
  - `{:error, reason}` - Error occurred during stitching
  """
  def stitch_job(job_id) do
    Logger.info("[StitchWorker] Starting video stitching for job #{job_id}")

    # Update progress to stitching stage
    Coordinator.update_progress(job_id, %{
      percentage: 80,
      stage: "stitching_videos"
    })

    with {:ok, job} <- fetch_job(job_id),
         {:ok, sub_jobs} <- fetch_sub_jobs(job_id),
         :ok <- validate_sub_jobs(sub_jobs),
         :ok <- check_ffmpeg(),
         :ok <- check_disk_space(),
         temp_dir <- create_temp_directory(job_id),
         {:ok, video_files} <- extract_videos(temp_dir, sub_jobs),
         {:ok, concat_file} <- create_concat_file(temp_dir, video_files),
         {:ok, output_file} <- stitch_videos(concat_file, temp_dir),
         {:ok, result_blob} <- read_result(output_file),
         {:ok, job} <- save_result(job, result_blob),
         :ok <- cleanup(temp_dir) do
      Logger.info("[StitchWorker] Successfully completed stitching for job #{job_id}")

      if Coordinator.auto_audio_enabled?() do
        case Coordinator.merge_audio_if_ready(job_id) do
          true ->
            Logger.info("[StitchWorker] Audio merged immediately after stitching for job #{job_id}")
            Coordinator.complete_job(job_id, job.result)

          _ ->
            Logger.info(
              "[StitchWorker] Waiting for audio merge before marking job #{job_id} complete"
            )
        end
      else
        Coordinator.complete_job(job_id, result_blob)
      end

      {:ok, result_blob}
    else
      {:error, reason} = error ->
        Logger.error("[StitchWorker] Stitching failed for job #{job_id}: #{inspect(reason)}")

        # Update progress with error
        Coordinator.update_progress(job_id, %{
          percentage: 80,
          stage: "stitching_failed",
          error: format_error(reason)
        })

        # Attempt cleanup even on failure
        temp_dir = get_temp_directory(job_id)
        cleanup(temp_dir)

        # Fail the job
        Coordinator.fail_job(job_id, reason)
        error
    end
  end

  @doc """
  Performs partial stitching if some sub_jobs failed.
  Only stitches completed sub_jobs together.

  ## Parameters
  - `job_id`: The ID of the job
  - `options`: Options map with:
    - `:skip_failed` - Skip failed sub_jobs (default: true)

  ## Returns
  - `{:ok, result}` - Successfully stitched available videos
  - `{:error, reason}` - Error occurred or no videos available
  """
  def partial_stitch(job_id, options \\ %{}) do
    skip_failed = Map.get(options, :skip_failed, true)

    Logger.info("[StitchWorker] Starting partial stitching for job #{job_id}")

    with {:ok, job} <- fetch_job(job_id),
         {:ok, sub_jobs} <- fetch_sub_jobs(job_id),
         {:ok, valid_sub_jobs} <- filter_valid_sub_jobs(sub_jobs, skip_failed),
         :ok <- validate_min_sub_jobs(valid_sub_jobs),
         :ok <- check_ffmpeg(),
         temp_dir <- create_temp_directory(job_id),
         {:ok, video_files} <- extract_videos(temp_dir, valid_sub_jobs),
         {:ok, concat_file} <- create_concat_file(temp_dir, video_files),
         {:ok, output_file} <- stitch_videos(concat_file, temp_dir),
         {:ok, result_blob} <- read_result(output_file),
         {:ok, job} <-
           save_partial_result(job, result_blob, length(valid_sub_jobs), length(sub_jobs)),
         :ok <- cleanup(temp_dir) do
      Logger.info(
        "[StitchWorker] Partial stitching completed for job #{job_id}: #{length(valid_sub_jobs)}/#{length(sub_jobs)} scenes"
      )

      {:ok, result_blob}
    else
      error ->
        Logger.error(
          "[StitchWorker] Partial stitching failed for job #{job_id}: #{inspect(error)}"
        )

        temp_dir = get_temp_directory(job_id)
        cleanup(temp_dir)
        error
    end
  end

  # Private Functions - Workflow Steps

  defp fetch_job(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        Logger.error("[StitchWorker] Job #{job_id} not found")
        {:error, :job_not_found}

      job ->
      {:ok, job}
    end
  end

  defp fetch_sub_jobs(job_id) do
    sub_jobs =
      SubJob
      |> where([s], s.job_id == ^job_id)
      |> order_by([s], asc: s.inserted_at)
      |> Repo.all()

    if Enum.empty?(sub_jobs) do
      Logger.error("[StitchWorker] No sub_jobs found for job #{job_id}")
      {:error, :no_sub_jobs}
    else
      Logger.info("[StitchWorker] Found #{length(sub_jobs)} sub_jobs for job #{job_id}")
      {:ok, sub_jobs}
    end
  end

  defp validate_sub_jobs(sub_jobs) do
    # Check that all sub_jobs are completed
    incomplete =
      sub_jobs
      |> Enum.reject(&(&1.status == :completed))

    if Enum.empty?(incomplete) do
      :ok
    else
      incomplete_ids = Enum.map(incomplete, & &1.id)
      Logger.error("[StitchWorker] Some sub_jobs are not completed: #{inspect(incomplete_ids)}")
      {:error, {:incomplete_sub_jobs, incomplete_ids}}
    end
  end

  defp filter_valid_sub_jobs(sub_jobs, skip_failed) do
    valid_sub_jobs =
      if skip_failed do
        sub_jobs
        |> Enum.filter(&(&1.status == :completed))
        |> Enum.reject(&(is_nil(&1.video_blob) or &1.video_blob == ""))
      else
        sub_jobs
      end

    if Enum.empty?(valid_sub_jobs) do
      {:error, :no_valid_sub_jobs}
    else
      {:ok, valid_sub_jobs}
    end
  end

  defp validate_min_sub_jobs(sub_jobs) do
    if length(sub_jobs) >= 1 do
      :ok
    else
      {:error, :insufficient_sub_jobs}
    end
  end

  defp check_ffmpeg do
    case FfmpegService.check_ffmpeg_available() do
      {:ok, version} ->
        Logger.info("[StitchWorker] FFmpeg available: #{version}")
        :ok

      {:error, reason} ->
        Logger.error("[StitchWorker] FFmpeg not available: #{inspect(reason)}")
        {:error, :ffmpeg_not_available}
    end
  end

  defp check_disk_space do
    # Check available disk space in /tmp
    case System.cmd("df", ["-m", @tmp_base_dir], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse df output to get available space
        available_mb = parse_available_space(output)

        if available_mb >= @min_free_space_mb do
          Logger.debug("[StitchWorker] Sufficient disk space: #{available_mb} MB available")
          :ok
        else
          Logger.error(
            "[StitchWorker] Insufficient disk space: #{available_mb} MB available, need #{@min_free_space_mb} MB"
          )

          {:error, :insufficient_disk_space}
        end

      _ ->
        # If we can't check, proceed anyway and handle errors later
        Logger.warning("[StitchWorker] Could not check disk space, proceeding anyway")
        :ok
    end
  end

  defp create_temp_directory(job_id) do
    temp_dir = get_temp_directory(job_id)

    # Clean up any existing directory first
    if File.exists?(temp_dir) do
      Logger.warning("[StitchWorker] Temp directory already exists, cleaning up: #{temp_dir}")
      File.rm_rf!(temp_dir)
    end

    File.mkdir_p!(temp_dir)
    Logger.info("[StitchWorker] Created temp directory: #{temp_dir}")

    temp_dir
  end

  defp get_temp_directory(job_id) do
    Path.join(@tmp_base_dir, "job_#{job_id}")
  end

  defp extract_videos(temp_dir, sub_jobs) do
    Logger.info("[StitchWorker] Extracting #{length(sub_jobs)} video blobs to temp files")

    case FfmpegService.extract_video_blobs(temp_dir, sub_jobs) do
      {:ok, video_files} ->
        Logger.info("[StitchWorker] Successfully extracted #{length(video_files)} video files")
        {:ok, video_files}

      {:error, reason} ->
        Logger.error("[StitchWorker] Failed to extract video blobs: #{inspect(reason)}")
        {:error, {:extraction_failed, reason}}
    end
  end

  defp create_concat_file(temp_dir, video_files) do
    concat_file_path = Path.join(temp_dir, "concat.txt")

    Logger.info("[StitchWorker] Creating concat file: #{concat_file_path}")

    case FfmpegService.generate_concat_file(concat_file_path, video_files) do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} ->
        Logger.error("[StitchWorker] Failed to create concat file: #{inspect(reason)}")
        {:error, {:concat_file_failed, reason}}
    end
  end

  defp stitch_videos(concat_file, temp_dir) do
    output_file = Path.join(temp_dir, "output.mp4")

    Logger.info("[StitchWorker] Starting FFmpeg stitching to: #{output_file}")

    case FfmpegService.stitch_videos(concat_file, output_file) do
      {:ok, path} ->
        # Verify file size
        case File.stat(path) do
          {:ok, %{size: size}} ->
            size_mb = size / (1024 * 1024)
            Logger.info("[StitchWorker] Stitched video created: #{Float.round(size_mb, 2)} MB")
            {:ok, path}

          {:error, reason} ->
            Logger.error("[StitchWorker] Failed to stat output file: #{inspect(reason)}")
            {:error, :output_file_stat_failed}
        end

      {:error, reason} ->
        Logger.error("[StitchWorker] FFmpeg stitching failed: #{inspect(reason)}")
        {:error, {:ffmpeg_failed, reason}}
    end
  end

  defp read_result(output_file) do
    Logger.info("[StitchWorker] Reading stitched video into memory")

    case FfmpegService.read_video_file(output_file) do
      {:ok, binary} ->
        {:ok, binary}

      {:error, reason} ->
        Logger.error("[StitchWorker] Failed to read result file: #{inspect(reason)}")
        {:error, {:read_failed, reason}}
    end
  end

  defp save_result(job, result_blob) do
    Logger.info("[StitchWorker] Saving result to job #{job.id}")

    changeset =
      Job.changeset(job, %{
        result: result_blob,
        progress: %{percentage: 90, stage: "stitching_complete"}
      })

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        Logger.info("[StitchWorker] Result saved successfully")
        {:ok, updated_job}

      {:error, changeset} ->
        Logger.error("[StitchWorker] Failed to save result: #{inspect(changeset.errors)}")
        {:error, :save_failed}
    end
  end

  defp save_partial_result(job, result_blob, completed_count, total_count) do
    Logger.info(
      "[StitchWorker] Saving partial result to job #{job.id} (#{completed_count}/#{total_count} scenes)"
    )

    changeset =
      Job.changeset(job, %{
        result: result_blob,
        status: :completed,
        progress: %{
          percentage: 100,
          stage: "completed_partial",
          completed_scenes: completed_count,
          total_scenes: total_count
        }
      })

    case Repo.update(changeset) do
      {:ok, updated_job} ->
        Logger.info("[StitchWorker] Partial result saved successfully")
        {:ok, updated_job}

      {:error, changeset} ->
        Logger.error("[StitchWorker] Failed to save partial result: #{inspect(changeset.errors)}")
        {:error, :save_failed}
    end
  end

  defp cleanup(temp_dir) do
    Logger.info("[StitchWorker] Cleaning up temp directory: #{temp_dir}")
    FfmpegService.cleanup_temp_files(temp_dir)
  end

  # Helper Functions

  defp parse_available_space(df_output) do
    # Parse df output to extract available space in MB
    # Example output:
    # Filesystem     1M-blocks  Used Available Use% Mounted on
    # /dev/sda1         100000 50000     50000  50% /tmp
    df_output
    |> String.split("\n")
    |> Enum.at(1, "")
    |> String.split()
    |> Enum.at(3, "0")
    |> String.to_integer()
  rescue
    _ -> 0
  end

  defp format_error(reason) do
    case reason do
      :job_not_found -> "Job not found"
      :no_sub_jobs -> "No sub_jobs found for job"
      {:incomplete_sub_jobs, ids} -> "Sub_jobs not completed: #{inspect(ids)}"
      :no_valid_sub_jobs -> "No valid sub_jobs with video data"
      :insufficient_sub_jobs -> "Not enough sub_jobs to stitch"
      :ffmpeg_not_available -> "FFmpeg is not installed or not available"
      :insufficient_disk_space -> "Insufficient disk space in /tmp"
      {:extraction_failed, reason} -> "Video extraction failed: #{inspect(reason)}"
      {:concat_file_failed, reason} -> "Concat file creation failed: #{inspect(reason)}"
      {:ffmpeg_failed, reason} -> "FFmpeg stitching failed: #{inspect(reason)}"
      {:read_failed, reason} -> "Failed to read result file: #{inspect(reason)}"
      :save_failed -> "Failed to save result to database"
      :output_file_stat_failed -> "Failed to verify output file"
      other -> inspect(other)
    end
  end
end
