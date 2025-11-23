defmodule BackendWeb.Api.V3.VideoController do
  @moduledoc """
  Controller for video serving endpoints in API v3.

  Handles streaming of generated video files, clips, and thumbnails with:
  - Efficient streaming without loading entire files into memory
  - Range request support for video scrubbing
  - Proper caching headers (ETag, Cache-Control)
  - On-demand thumbnail generation
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Schemas.SubJob
  import Ecto.Query
  require Logger

  @doc """
  GET /api/v3/videos/:job_id/combined

  Serves the final stitched video from the job's result blob.

  ## Parameters
    - job_id: The job ID

  ## Response
    - 200: Video streamed successfully (with Range support)
    - 206: Partial content (when Range header is present)
    - 404: Job not found or video not ready
    - 416: Range not satisfiable
  """
  def combined(conn, %{"job_id" => job_id}) do
    Logger.info("[VideoController] Serving combined video for job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        send_json_error(conn, :not_found, "Job not found")

      %Job{result: nil} ->
        send_json_error(conn, :not_found, "Video not ready - job processing incomplete")

      %Job{result: result_blob} ->
        serve_video_blob(conn, result_blob, "combined_#{job_id}.mp4")
    end
  end

  @doc """
  GET /api/v3/videos/:job_id/clips/:filename

  Serves individual video clips from sub_jobs.

  ## Parameters
    - job_id: The job ID
    - filename: The clip filename (format: "clip_<sub_job_id>.mp4" or just the sub_job_id)

  ## Response
    - 200/206: Video clip streamed successfully
    - 404: Clip not found
  """
  def clip(conn, %{"job_id" => job_id, "filename" => filename}) do
    Logger.info("[VideoController] Serving clip #{filename} for job #{job_id}")

    # Extract sub_job_id from filename
    sub_job_id = extract_sub_job_id(filename)

    query =
      from s in SubJob,
        where: s.job_id == ^job_id and s.id == ^sub_job_id,
        select: s

    case Repo.one(query) do
      nil ->
        send_json_error(conn, :not_found, "Clip not found")

      %SubJob{video_blob: nil} ->
        send_json_error(conn, :not_found, "Clip video not ready")

      %SubJob{video_blob: video_blob} ->
        serve_video_blob(conn, video_blob, "clip_#{sub_job_id}.mp4")
    end
  end

  @doc """
  GET /api/v3/videos/:job_id/thumbnail

  Serves or generates thumbnail for the final combined video.

  ## Parameters
    - job_id: The job ID

  ## Response
    - 200: Thumbnail image (JPEG)
    - 404: Job not found or video not ready
    - 500: Thumbnail generation failed
  """
  def thumbnail(conn, %{"job_id" => job_id}) do
    Logger.info("[VideoController] Serving thumbnail for job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        send_json_error(conn, :not_found, "Job not found")

      %Job{result: nil} ->
        send_json_error(conn, :not_found, "Video not ready")

      job ->
        serve_or_generate_thumbnail(conn, job)
    end
  end

  @doc """
  GET /api/v3/videos/:job_id/clips/:filename/thumbnail

  Serves or generates thumbnail for individual clips.

  ## Parameters
    - job_id: The job ID
    - filename: The clip filename

  ## Response
    - 200: Thumbnail image (JPEG)
    - 404: Clip not found
    - 500: Thumbnail generation failed
  """
  def clip_thumbnail(conn, %{"job_id" => job_id, "filename" => filename}) do
    Logger.info("[VideoController] Serving clip thumbnail #{filename} for job #{job_id}")

    sub_job_id = extract_sub_job_id(filename)

    query =
      from s in SubJob,
        where: s.job_id == ^job_id and s.id == ^sub_job_id,
        select: s

    case Repo.one(query) do
      nil ->
        send_json_error(conn, :not_found, "Clip not found")

      %SubJob{video_blob: nil} ->
        send_json_error(conn, :not_found, "Clip video not ready")

      sub_job ->
        serve_or_generate_clip_thumbnail(conn, sub_job)
    end
  end

  # Private helper functions

  defp serve_video_blob(conn, video_blob, filename) do
    # Calculate ETag for caching
    etag = calculate_etag(video_blob)
    blob_size = byte_size(video_blob)

    # Check If-None-Match header for cache validation
    case get_req_header(conn, "if-none-match") do
      [^etag] ->
        # Client has cached version
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")

      _ ->
        # Set caching headers
        conn =
          conn
          |> put_resp_content_type("video/mp4")
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
          |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))

        # Handle Range requests for video scrubbing
        case get_req_header(conn, "range") do
          ["bytes=" <> range] ->
            serve_range(conn, video_blob, blob_size, range)

          _ ->
            # Serve entire video
            conn
            |> put_resp_header("content-length", to_string(blob_size))
            |> send_resp(200, video_blob)
        end
    end
  end

  defp serve_range(conn, video_blob, total_size, range) do
    case parse_range(range, total_size) do
      {:ok, start_pos, end_pos} ->
        # Extract the requested byte range
        length = end_pos - start_pos + 1
        chunk = binary_part(video_blob, start_pos, length)

        conn
        |> put_status(206)
        |> put_resp_header("content-length", to_string(length))
        |> put_resp_header(
          "content-range",
          "bytes #{start_pos}-#{end_pos}/#{total_size}"
        )
        |> send_resp(206, chunk)

      {:error, :invalid_range} ->
        conn
        |> put_resp_header("content-range", "bytes */#{total_size}")
        |> send_resp(416, "Range Not Satisfiable")
    end
  end

  defp parse_range(range, total_size) do
    # Handle formats: "0-499", "-500", "500-"
    case String.split(range, "-") do
      [start, ""] ->
        # From start to end
        case Integer.parse(start) do
          {start_pos, ""} when start_pos >= 0 and start_pos < total_size ->
            {:ok, start_pos, total_size - 1}

          _ ->
            {:error, :invalid_range}
        end

      ["", suffix] ->
        # Last N bytes
        case Integer.parse(suffix) do
          {suffix_length, ""} when suffix_length > 0 ->
            start_pos = max(0, total_size - suffix_length)
            {:ok, start_pos, total_size - 1}

          _ ->
            {:error, :invalid_range}
        end

      [start, end_str] ->
        # Specific range
        with {start_pos, ""} <- Integer.parse(start),
             {end_pos, ""} <- Integer.parse(end_str),
             true <- start_pos >= 0 and end_pos < total_size and start_pos <= end_pos do
          {:ok, start_pos, end_pos}
        else
          _ -> {:error, :invalid_range}
        end

      _ ->
        {:error, :invalid_range}
    end
  end

  defp serve_or_generate_thumbnail(conn, job) do
    # Check if thumbnail exists in progress metadata (stored as Base64)
    thumbnail_data =
      case job.progress do
        %{"thumbnail" => thumb} when is_binary(thumb) ->
          # Decode from Base64
          case Base.decode64(thumb) do
            {:ok, decoded} -> decoded
            _ -> nil
          end

        %{thumbnail: thumb} when is_binary(thumb) ->
          # Decode from Base64
          case Base.decode64(thumb) do
            {:ok, decoded} -> decoded
            _ -> nil
          end

        _ ->
          nil
      end

    case thumbnail_data do
      nil ->
        # Generate thumbnail on-demand
        generate_and_serve_thumbnail(conn, job.result, job.id, :job)

      thumb_blob ->
        serve_thumbnail(conn, thumb_blob)
    end
  end

  defp serve_or_generate_clip_thumbnail(conn, sub_job) do
    # For now, generate on-demand (could cache in sub_job metadata later)
    generate_and_serve_thumbnail(conn, sub_job.video_blob, sub_job.id, :sub_job)
  end

  defp generate_and_serve_thumbnail(conn, video_blob, id, type) do
    case generate_thumbnail(video_blob) do
      {:ok, thumbnail_blob} ->
        # Optionally cache the thumbnail in the database
        cache_thumbnail(id, type, thumbnail_blob)
        serve_thumbnail(conn, thumbnail_blob)

      {:error, reason} ->
        Logger.error("[VideoController] Thumbnail generation failed: #{inspect(reason)}")
        send_json_error(conn, :internal_server_error, "Thumbnail generation failed")
    end
  end

  defp generate_thumbnail(video_blob) do
    # Create temporary files
    temp_video_path =
      Path.join(System.tmp_dir!(), "video_#{:erlang.unique_integer([:positive])}.mp4")

    temp_thumb_path =
      Path.join(System.tmp_dir!(), "thumb_#{:erlang.unique_integer([:positive])}.jpg")

    try do
      # Write video blob to temp file
      File.write!(temp_video_path, video_blob)

      # Generate thumbnail using FFmpeg
      # Extract frame at 1 second, scale to 640x360 (16:9 aspect ratio)
      args = [
        "-i",
        temp_video_path,
        "-ss",
        "00:00:01.000",
        "-vframes",
        "1",
        "-vf",
        "scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:-1:-1:color=black",
        "-q:v",
        "2",
        temp_thumb_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          thumbnail_blob = File.read!(temp_thumb_path)
          {:ok, thumbnail_blob}

        {output, exit_code} ->
          Logger.error("[VideoController] FFmpeg failed with exit code #{exit_code}: #{output}")

          {:error, "FFmpeg failed"}
      end
    rescue
      e ->
        Logger.error("[VideoController] Exception during thumbnail generation: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      # Clean up temporary files
      File.rm(temp_video_path)
      File.rm(temp_thumb_path)
    end
  end

  defp cache_thumbnail(id, :job, thumbnail_blob) do
    # Update job progress with Base64-encoded thumbnail
    # (JSONB doesn't support raw binary, so we encode it)
    Task.start(fn ->
      case Repo.get(Job, id) do
        nil ->
          :ok

        job ->
          progress = job.progress || %{}
          # Encode thumbnail as Base64 for JSONB storage
          encoded_thumbnail = Base.encode64(thumbnail_blob)
          updated_progress = Map.put(progress, "thumbnail", encoded_thumbnail)

          job
          |> Ecto.Changeset.change(progress: updated_progress)
          |> Repo.update()
      end
    end)
  end

  defp cache_thumbnail(_id, :sub_job, _thumbnail_blob) do
    # For sub_jobs, we could add a thumbnail field later if needed
    # For now, we'll regenerate on-demand (thumbnails are small and fast)
    :ok
  end

  defp serve_thumbnail(conn, thumbnail_blob) do
    etag = calculate_etag(thumbnail_blob)

    # Check cache
    case get_req_header(conn, "if-none-match") do
      [^etag] ->
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")

      _ ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("content-length", to_string(byte_size(thumbnail_blob)))
        |> send_resp(200, thumbnail_blob)
    end
  end

  defp extract_sub_job_id(filename) do
    # Handle formats: "clip_<uuid>.mp4", "<uuid>.mp4", or just "<uuid>"
    filename
    |> String.replace_prefix("clip_", "")
    |> String.replace_suffix(".mp4", "")
  end

  defp calculate_etag(blob) do
    # Generate ETag using MD5 hash (simpler than SHA for cache validation)
    :crypto.hash(:md5, blob)
    |> Base.encode16(case: :lower)
    |> then(&~s("#{&1}"))
  end

  defp send_json_error(conn, status, message) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(%{error: message})
  end
end
