defmodule Backend.Services.ReplicateService do
  @moduledoc """
  Service for integrating with Replicate API for video rendering.

  Handles:
  - Starting video rendering jobs
  - Polling for job completion
  - Exponential backoff for polling
  - Error handling and retries
  """
  require Logger

  @base_url "https://api.replicate.com/v1"
  # 1 second
  @initial_backoff 1_000
  # 60 seconds
  @max_backoff 60_000
  @max_retries 30
  # 30 minutes
  @timeout 1_800_000

  @doc """
  Starts a rendering job on Replicate.

  ## Parameters
    - scene: Map containing scene data with prompt and parameters
    - options: Additional rendering options (optional)

  ## Returns
    - {:ok, %{id: prediction_id, status: status}} on success
    - {:error, reason} on failure

  ## Example
      iex> ReplicateService.start_render(%{
        prompt: "A cat jumping",
        duration: 5,
        aspect_ratio: "16:9"
      })
      {:ok, %{id: "abc123", status: "starting"}}
  """
  def start_render(scene, options \\ %{}) do
    api_key = get_api_key()

    payload = build_render_payload(scene, options)

    headers = [
      {"Authorization", "Token #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@base_url}/predictions"

    Logger.info("[ReplicateService] Starting render for scene with payload: #{inspect(payload)}")

    case Req.post(url, json: payload, headers: headers, retry: :transient, max_retries: 3) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.info("[ReplicateService] Render started successfully: #{inspect(body)}")
        {:ok, %{id: body["id"], status: body["status"], urls: body["urls"]}}

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[ReplicateService] Failed to start render. Status: #{status}, Body: #{inspect(body)}"
        )

        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[ReplicateService] Request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Polls for the completion of a rendering job with exponential backoff.

  ## Parameters
    - prediction_id: The ID of the prediction to poll
    - options: Polling options (max_retries, timeout)

  ## Returns
    - {:ok, %{status: "succeeded", output: video_url}} on success
    - {:error, reason} on failure or timeout

  ## Example
      iex> ReplicateService.poll_until_complete("abc123")
      {:ok, %{status: "succeeded", output: "https://..."}}
  """
  def poll_until_complete(prediction_id, options \\ %{}) do
    max_retries = Map.get(options, :max_retries, @max_retries)
    timeout = Map.get(options, :timeout, @timeout)
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[ReplicateService] Starting to poll prediction: #{prediction_id}")

    poll_with_backoff(prediction_id, 0, @initial_backoff, max_retries, start_time, timeout)
  end

  @doc """
  Fetches the current status of a prediction.

  ## Parameters
    - prediction_id: The ID of the prediction

  ## Returns
    - {:ok, prediction_data} on success
    - {:error, reason} on failure
  """
  def get_prediction(prediction_id) do
    api_key = get_api_key()

    headers = [
      {"Authorization", "Token #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@base_url}/predictions/#{prediction_id}"

    case Req.get(url, headers: headers, retry: :transient, max_retries: 3) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[ReplicateService] Failed to get prediction. Status: #{status}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[ReplicateService] Request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Downloads the video blob from a URL.

  ## Parameters
    - video_url: The URL of the video to download

  ## Returns
    - {:ok, binary_data} on success
    - {:error, reason} on failure
  """
  def download_video(video_url) do
    Logger.info("[ReplicateService] Downloading video from: #{video_url}")

    case Req.get(video_url, max_retries: 3, retry_delay: 1000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.info(
          "[ReplicateService] Video downloaded successfully, size: #{byte_size(body)} bytes"
        )

        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.error("[ReplicateService] Failed to download video. Status: #{status}")
        {:error, {:download_failed, status}}

      {:error, reason} ->
        Logger.error("[ReplicateService] Download request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Cancels a running prediction.

  ## Parameters
    - prediction_id: The ID of the prediction to cancel

  ## Returns
    - {:ok, prediction_data} on success
    - {:error, reason} on failure
  """
  def cancel_prediction(prediction_id) do
    api_key = get_api_key()

    headers = [
      {"Authorization", "Token #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@base_url}/predictions/#{prediction_id}/cancel"

    Logger.info("[ReplicateService] Cancelling prediction: #{prediction_id}")

    case Req.post(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.info("[ReplicateService] Prediction cancelled successfully")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[ReplicateService] Failed to cancel prediction. Status: #{status}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[ReplicateService] Cancel request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # Private Functions

  defp poll_with_backoff(prediction_id, retry_count, backoff, max_retries, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)
    elapsed = current_time - start_time

    cond do
      elapsed > timeout ->
        Logger.error(
          "[ReplicateService] Polling timeout after #{elapsed}ms for prediction: #{prediction_id}"
        )

        {:error, :timeout}

      retry_count >= max_retries ->
        Logger.error(
          "[ReplicateService] Max retries (#{max_retries}) reached for prediction: #{prediction_id}"
        )

        {:error, :max_retries_exceeded}

      true ->
        case get_prediction(prediction_id) do
          {:ok, %{"status" => "succeeded"} = prediction} ->
            Logger.info("[ReplicateService] Prediction succeeded: #{prediction_id}")
            {:ok, prediction}

          {:ok, %{"status" => "failed", "error" => error}} ->
            Logger.error(
              "[ReplicateService] Prediction failed: #{prediction_id}, error: #{error}"
            )

            {:error, {:prediction_failed, error}}

          {:ok, %{"status" => "canceled"}} ->
            Logger.warning("[ReplicateService] Prediction was canceled: #{prediction_id}")
            {:error, :canceled}

          {:ok, %{"status" => status}} when status in ["starting", "processing"] ->
            Logger.debug(
              "[ReplicateService] Prediction #{prediction_id} still #{status}, waiting #{backoff}ms (retry #{retry_count + 1}/#{max_retries})"
            )

            Process.sleep(backoff)

            # Calculate next backoff with exponential increase, capped at max
            next_backoff = min(backoff * 2, @max_backoff)

            poll_with_backoff(
              prediction_id,
              retry_count + 1,
              next_backoff,
              max_retries,
              start_time,
              timeout
            )

          {:error, reason} ->
            Logger.warning(
              "[ReplicateService] Error fetching prediction status: #{inspect(reason)}, retrying in #{backoff}ms"
            )

            Process.sleep(backoff)

            next_backoff = min(backoff * 2, @max_backoff)

            poll_with_backoff(
              prediction_id,
              retry_count + 1,
              next_backoff,
              max_retries,
              start_time,
              timeout
            )
        end
    end
  end

  defp build_render_payload(scene, options) do
    # Default model - can be overridden in options
    model =
      Map.get(
        options,
        :model,
        "stability-ai/stable-video-diffusion:3f0457e4619daac51203dedb472816fd4af51f3149fa7a9e0b5ffcf1b8172438"
      )

    # Build input parameters from scene data
    input = %{
      "prompt" => Map.get(scene, :prompt, Map.get(scene, "prompt", "")),
      "duration" => Map.get(scene, :duration, Map.get(scene, "duration", 5)),
      "aspect_ratio" => Map.get(scene, :aspect_ratio, Map.get(scene, "aspect_ratio", "16:9"))
    }

    # Merge with any additional options
    input = Map.merge(input, Map.get(options, :additional_params, %{}))

    %{
      "version" => model,
      "input" => input
    }
  end

  defp get_api_key do
    case Application.get_env(:backend, :replicate_api_key) do
      nil ->
        raise "REPLICATE_API_KEY not configured. Please set the environment variable."

      "" ->
        raise "REPLICATE_API_KEY is empty. Please set a valid API key."

      key ->
        key
    end
  end
end
