defmodule BackendWeb.Api.V3.AudioController do
  @moduledoc """
  Controller for audio generation endpoints in API v3.

  Handles audio generation for video jobs with sequential scene processing
  and optional video/audio merging.
  """
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.Job
  alias Backend.Workflow.AudioWorker
  require Logger

  @doc """
  POST /api/v3/audio/generate-scenes

  Generates audio for all scenes in a job with sequential chaining.

  ## Parameters (JSON body)
    - job_id: The job ID to generate audio for (required)
    - audio_params: Map with audio generation parameters (optional):
      - fade_duration: Fade duration between segments (default: 1.0)
      - sync_mode: How to sync with video - "trim", "stretch", or "compress" (default: "trim")
      - merge_with_video: Whether to merge audio with existing video (default: false)
      - error_strategy: How to handle errors - "continue_with_silence" or "halt" (default: "continue_with_silence")
      - prompt: Custom music generation prompt (optional)
      - provider: Music provider - "musicgen" or "elevenlabs" (default: "musicgen")

  ## Response
    - 202 Accepted: Audio generation started (returns job_id and status)
    - 400 Bad Request: Missing or invalid parameters
    - 404 Not Found: Job not found
    - 422 Unprocessable Entity: Job not ready for audio generation

  ## Example Request
  ```json
  {
    "job_id": "123",
    "audio_params": {
      "fade_duration": 1.5,
      "sync_mode": "trim",
      "merge_with_video": true,
      "error_strategy": "continue_with_silence"
    }
  }
  ```

  ## Example Response
  ```json
  {
    "job_id": "123",
    "status": "processing",
    "message": "Audio generation started",
    "audio_status": {
      "started_at": "2024-01-15T10:30:00Z",
      "estimated_duration": "45s"
    }
  }
  ```
  """
  def generate_scenes(conn, params) do
    Logger.info("[AudioController] Audio generation request: #{inspect(params)}")

    with {:ok, job_id} <- extract_job_id(params),
         {:ok, job} <- load_and_validate_job(job_id),
         {:ok, audio_params} <- parse_audio_params(params) do
      # Start audio generation asynchronously
      start_async_audio_generation(job, audio_params)

      # Return immediate response
      conn
      |> put_status(:accepted)
      |> json(%{
        job_id: job.id,
        status: "processing",
        message: "Audio generation started",
        audio_status: %{
          started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          estimated_duration: estimate_duration(job)
        }
      })
    else
      {:error, :missing_job_id} ->
        send_error(conn, :bad_request, "Missing required parameter: job_id")

      {:error, :job_not_found} ->
        send_error(conn, :not_found, "Job not found")

      {:error, :no_storyboard} ->
        send_error(conn, :unprocessable_entity, "Job has no storyboard - cannot generate audio")

      {:error, reason} when is_binary(reason) ->
        send_error(conn, :bad_request, reason)

      {:error, reason} ->
        send_error(
          conn,
          :internal_server_error,
          "Failed to start audio generation: #{inspect(reason)}"
        )
    end
  end

  @doc """
  GET /api/v3/audio/status/:job_id

  Get audio generation status for a job.

  ## Response
    - 200 OK: Returns audio generation status
    - 404 Not Found: Job not found
  """
  def status(conn, %{"job_id" => job_id}) do
    Logger.info("[AudioController] Audio status request for job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        send_error(conn, :not_found, "Job not found")

      job ->
        audio_status = extract_audio_status(job)

        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job.id,
          audio_status: audio_status
        })
    end
  end

  @doc """
  GET /api/v3/audio/:job_id/download

  Download the generated audio file for a job.

  ## Response
    - 200 OK: Audio file (MP3)
    - 404 Not Found: Job not found or audio not ready
  """
  def download(conn, %{"job_id" => job_id}) do
    Logger.info("[AudioController] Audio download request for job #{job_id}")

    case Repo.get(Job, job_id) do
      nil ->
        send_error(conn, :not_found, "Job not found")

      job ->
        case extract_audio_blob(job) do
          nil ->
            send_error(conn, :not_found, "Audio not ready or not generated")

          audio_blob ->
            serve_audio_blob(conn, audio_blob, "audio_#{job_id}.mp3")
        end
    end
  end

  # Private helper functions

  defp extract_job_id(%{"job_id" => job_id}) when is_binary(job_id) or is_integer(job_id) do
    {:ok, job_id}
  end

  defp extract_job_id(_params) do
    {:error, :missing_job_id}
  end

  defp load_and_validate_job(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        {:error, :job_not_found}

      %Job{storyboard: nil} ->
        {:error, :no_storyboard}

      job ->
        {:ok, job}
    end
  end

  defp parse_audio_params(params) do
    audio_params = params["audio_params"] || %{}

    parsed_params = %{
      fade_duration: parse_float(audio_params["fade_duration"], 1.0),
      sync_mode: parse_sync_mode(audio_params["sync_mode"]),
      merge_with_video: parse_boolean(audio_params["merge_with_video"], false),
      error_strategy: parse_error_strategy(audio_params["error_strategy"]),
      prompt: audio_params["prompt"],
      provider: parse_provider(audio_params["provider"])
    }

    {:ok, parsed_params}
  rescue
    e ->
      Logger.error("[AudioController] Failed to parse audio params: #{inspect(e)}")
      {:error, "Invalid audio parameters"}
  end

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value * 1.0

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp parse_sync_mode(nil), do: :trim
  defp parse_sync_mode("trim"), do: :trim
  defp parse_sync_mode("stretch"), do: :stretch
  defp parse_sync_mode("compress"), do: :compress
  defp parse_sync_mode(_), do: :trim

  defp parse_boolean(nil, default), do: default
  defp parse_boolean(true, _), do: true
  defp parse_boolean(false, _), do: false
  defp parse_boolean("true", _), do: true
  defp parse_boolean("false", _), do: false
  defp parse_boolean(_, default), do: default

  defp parse_error_strategy(nil), do: :continue_with_silence
  defp parse_error_strategy("continue_with_silence"), do: :continue_with_silence
  defp parse_error_strategy("halt"), do: :halt
  defp parse_error_strategy(_), do: :continue_with_silence

  defp parse_provider(nil), do: "musicgen"
  defp parse_provider("elevenlabs"), do: "elevenlabs"
  defp parse_provider("musicgen"), do: "musicgen"
  defp parse_provider(_), do: "musicgen"

  defp start_async_audio_generation(job, audio_params) do
    # Start audio generation in a background task
    Task.start(fn ->
      try do
        Logger.info("[AudioController] Starting background audio generation for job #{job.id}")

        case AudioWorker.generate_job_audio(job.id, audio_params) do
          {:ok, _updated_job} ->
            Logger.info("[AudioController] Audio generation completed for job #{job.id}")

          {:error, reason} ->
            Logger.error("[AudioController] Audio generation failed for job #{job.id}: #{reason}")
        end
      rescue
        e ->
          Logger.error("[AudioController] Exception during audio generation: #{inspect(e)}")

          Logger.error(
            "[AudioController] Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
          )
      end
    end)
  end

  defp estimate_duration(job) do
    # Estimate based on number of scenes
    scene_count =
      case job.storyboard do
        scenes when is_list(scenes) -> length(scenes)
        %{"scenes" => scenes} when is_list(scenes) -> length(scenes)
        %{scenes: scenes} when is_list(scenes) -> length(scenes)
        _ -> 1
      end

    # Rough estimate: 10 seconds per scene for API processing
    estimated_seconds = scene_count * 10
    "~#{estimated_seconds}s"
  end

  defp extract_audio_status(job) do
    progress = job.progress || %{}

    %{
      status: Map.get(progress, "audio_status", "not_started"),
      generated_at: Map.get(progress, "audio_generated_at"),
      size: Map.get(progress, "audio_size"),
      merged_with_video: Map.get(progress, "video_with_audio", false),
      error: Map.get(progress, "error")
    }
  end

  defp extract_audio_blob(job) do
    # Return audio from dedicated audio_blob field
    job.audio_blob
  end

  defp serve_audio_blob(conn, audio_blob, filename) do
    etag = calculate_etag(audio_blob)

    # Check cache
    case get_req_header(conn, "if-none-match") do
      [^etag] ->
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")

      _ ->
        conn
        |> put_resp_content_type("audio/mpeg")
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("content-length", to_string(byte_size(audio_blob)))
        |> send_resp(200, audio_blob)
    end
  end

  defp calculate_etag(blob) do
    :crypto.hash(:md5, blob)
    |> Base.encode16(case: :lower)
    |> then(&~s("#{&1}"))
  end

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
