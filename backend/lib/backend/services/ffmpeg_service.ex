defmodule Backend.Services.FfmpegService do
  @moduledoc """
  Service for video stitching operations using FFmpeg.

  Provides functionality to:
  - Extract video blobs to temporary files
  - Generate concat.txt for FFmpeg
  - Execute FFmpeg video stitching
  - Clean up temporary files
  """

  require Logger

  @doc """
  Checks if FFmpeg is available on the system.
  Returns {:ok, version} or {:error, reason}.
  """
  def check_ffmpeg_available do
    case System.cmd("ffmpeg", ["-version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = extract_version(output)
        {:ok, version}

      {_output, _code} ->
        {:error, :ffmpeg_not_found}
    end
  rescue
    e ->
      Logger.error("[FFmpegService] Error checking FFmpeg: #{inspect(e)}")
      {:error, :ffmpeg_check_failed}
  end

  @doc """
  Extracts video blobs from sub_jobs to temporary files.

  ## Parameters
  - `temp_dir`: Directory to extract files to
  - `sub_jobs`: List of sub_jobs with video_blob field

  ## Returns
  - `{:ok, file_paths}` - List of created file paths in order
  - `{:error, reason}` - Error occurred during extraction
  """
  def extract_video_blobs(temp_dir, sub_jobs) do
    try do
      # Ensure temp directory exists
      File.mkdir_p!(temp_dir)

      # Sort sub_jobs by ID to maintain order
      sorted_sub_jobs = Enum.sort_by(sub_jobs, & &1.id)

      file_paths =
        sorted_sub_jobs
        |> Enum.with_index()
        |> Enum.map(fn {sub_job, index} ->
          extract_single_blob(temp_dir, sub_job, index)
        end)

      # Check if all extractions succeeded
      if Enum.all?(file_paths, &match?({:ok, _}, &1)) do
        paths = Enum.map(file_paths, fn {:ok, path} -> path end)
        {:ok, paths}
      else
        failed = Enum.find(file_paths, &match?({:error, _}, &1))
        failed
      end
    rescue
      e ->
        Logger.error("[FFmpegService] Error extracting video blobs: #{inspect(e)}")
        {:error, :extraction_failed}
    end
  end

  @doc """
  Generates a concat.txt file for FFmpeg.

  ## Parameters
  - `concat_file_path`: Path where concat.txt should be created
  - `video_file_paths`: List of video file paths to concatenate

  ## Returns
  - `{:ok, concat_file_path}` - Successfully created concat file
  - `{:error, reason}` - Error occurred
  """
  def generate_concat_file(concat_file_path, video_file_paths) do
    try do
      # Generate concat file content
      # Each line: file '/absolute/path/to/file.mp4'
      content =
        video_file_paths
        |> Enum.map(fn path -> "file '#{path}'" end)
        |> Enum.join("\n")

      # Write concat file
      File.write!(concat_file_path, content)

      Logger.debug("[FFmpegService] Generated concat file at #{concat_file_path}")
      {:ok, concat_file_path}
    rescue
      e ->
        Logger.error("[FFmpegService] Error generating concat file: #{inspect(e)}")
        {:error, :concat_file_generation_failed}
    end
  end

  @doc """
  Executes FFmpeg to stitch videos together.

  ## Parameters
  - `concat_file_path`: Path to the concat.txt file
  - `output_path`: Path where the output video should be saved

  ## Returns
  - `{:ok, output_path}` - Successfully stitched video
  - `{:error, reason}` - Error occurred during stitching
  """
  def stitch_videos(concat_file_path, output_path) do
    # FFmpeg command: ffmpeg -f concat -safe 0 -i concat.txt -c copy output.mp4
    args = [
      "-f",
      "concat",
      "-safe",
      "0",
      "-i",
      concat_file_path,
      "-c",
      "copy",
      # Overwrite output file if exists
      "-y",
      output_path
    ]

    Logger.info("[FFmpegService] Starting FFmpeg stitching: #{output_path}")
    Logger.debug("[FFmpegService] FFmpeg args: #{inspect(args)}")

    try do
      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {output, 0} ->
          Logger.info("[FFmpegService] FFmpeg stitching completed successfully")
          Logger.debug("[FFmpegService] FFmpeg output: #{output}")

          # Verify output file exists
          if File.exists?(output_path) do
            {:ok, output_path}
          else
            Logger.error("[FFmpegService] Output file not created: #{output_path}")
            {:error, :output_file_not_created}
          end

        {output, exit_code} ->
          Logger.error("[FFmpegService] FFmpeg failed with exit code #{exit_code}")
          Logger.error("[FFmpegService] FFmpeg output: #{output}")
          {:error, {:ffmpeg_failed, exit_code, output}}
      end
    rescue
      e ->
        Logger.error("[FFmpegService] Error executing FFmpeg: #{inspect(e)}")
        {:error, :ffmpeg_execution_failed}
    end
  end

  @doc """
  Reads a video file into binary data.

  ## Parameters
  - `file_path`: Path to the video file

  ## Returns
  - `{:ok, binary}` - Successfully read file
  - `{:error, reason}` - Error occurred
  """
  def read_video_file(file_path) do
    try do
      case File.read(file_path) do
        {:ok, binary} ->
          size_mb = byte_size(binary) / (1024 * 1024)

          Logger.info(
            "[FFmpegService] Read video file: #{file_path} (#{Float.round(size_mb, 2)} MB)"
          )

          {:ok, binary}

        {:error, reason} ->
          Logger.error("[FFmpegService] Failed to read file #{file_path}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[FFmpegService] Error reading video file: #{inspect(e)}")
        {:error, :file_read_failed}
    end
  end

  @doc """
  Cleans up temporary directory and all files within it.

  ## Parameters
  - `temp_dir`: Directory to clean up

  ## Returns
  - `:ok` - Successfully cleaned up
  - `{:error, reason}` - Error occurred
  """
  def cleanup_temp_files(temp_dir) do
    try do
      if File.exists?(temp_dir) do
        File.rm_rf!(temp_dir)
        Logger.info("[FFmpegService] Cleaned up temp directory: #{temp_dir}")
      end

      :ok
    rescue
      e ->
        Logger.warning("[FFmpegService] Error cleaning up temp files: #{inspect(e)}")
        # Don't fail the job if cleanup fails, just log it
        :ok
    end
  end

  @doc """
  Gets the size of a directory in bytes.
  Useful for checking disk space before operations.
  """
  def get_directory_size(path) do
    try do
      case System.cmd("du", ["-sb", path], stderr_to_stdout: true) do
        {output, 0} ->
          size = output |> String.split() |> List.first() |> String.to_integer()
          {:ok, size}

        _ ->
          {:error, :size_check_failed}
      end
    rescue
      _ -> {:error, :size_check_failed}
    end
  end

  # Private Functions

  defp extract_single_blob(temp_dir, sub_job, index) do
    try do
      # Check if video_blob exists
      if is_nil(sub_job.video_blob) or sub_job.video_blob == "" do
        Logger.warning("[FFmpegService] Sub_job #{sub_job.id} has no video_blob, skipping")
        {:error, {:missing_video_blob, sub_job.id}}
      else
        # Generate filename: scene_1.mp4, scene_2.mp4, etc.
        filename = "scene_#{index + 1}.mp4"
        file_path = Path.join(temp_dir, filename)

        # Write blob to file
        File.write!(file_path, sub_job.video_blob)

        size_mb = byte_size(sub_job.video_blob) / (1024 * 1024)
        Logger.debug("[FFmpegService] Extracted #{filename} (#{Float.round(size_mb, 2)} MB)")

        {:ok, file_path}
      end
    rescue
      e ->
        Logger.error(
          "[FFmpegService] Error extracting blob for sub_job #{sub_job.id}: #{inspect(e)}"
        )

        {:error, {:blob_extraction_failed, sub_job.id}}
    end
  end

  defp extract_version(output) do
    # Extract version from FFmpeg output
    # Example: "ffmpeg version 4.4.2"
    case Regex.run(~r/ffmpeg version ([^\s]+)/, output) do
      [_, version] -> version
      _ -> "unknown"
    end
  end
end
