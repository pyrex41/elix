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
  def start_render(render_request, options \\ %{}) do
    api_key = get_api_key()

    with {:ok, payload} <- build_render_payload(render_request, options) do
      headers = [
        {"Authorization", "Token #{api_key}"},
        {"Content-Type", "application/json"}
      ]

      url = "#{@base_url}/predictions"

      Logger.info("[ReplicateService] Starting render for model #{render_request.model}")
      Logger.debug("[ReplicateService] Payload: #{inspect(payload, pretty: true)}")

      case Req.post(url, json: payload, headers: headers, retry: :transient, max_retries: 3) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          Logger.info("[ReplicateService] Render started successfully: #{body["id"]}")
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
    else
      {:error, reason} ->
        {:error, reason}
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

  defp build_render_payload(render_request, _options) do
    model_key = normalize_model_key(render_request.model)

    with {:ok, config} <- resolve_model_config(model_key),
         {:ok, version} <- resolve_model_version(config.slug),
         {:ok, input} <- config.builder.(render_request, config) do
      payload =
        %{
          "version" => version,
          "input" => input
        }
        |> maybe_attach_webhook()

      {:ok, payload}
    end
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

  defp normalize_model_key(model) do
    model
    |> to_string()
    |> String.downcase()
    |> case do
      value when value in ["veo3", "veo-3.1", "veo3.1", "google/veo-3.1"] ->
        "veo3"

      value
      when value in ["hilua", "hilua-2.5", "hailuo-2.5", "hailuo-2.0", "hailuo-02", "hailuo2"] ->
        "hilua-2.5"

      value ->
        value
    end
  end

  defp resolve_model_config("veo3"),
    do: {:ok, %{slug: veo_slug(), builder: &build_veo_input/2, key: "veo3"}}

  defp resolve_model_config("hilua-2.5"),
    do: {:ok, %{slug: hilua_slug(), builder: &build_hailuo_input/2, key: "hilua-2.5"}}

  defp resolve_model_config(other),
    do: {:error, {:unsupported_model, other}}

  defp veo_slug, do: System.get_env("REPLICATE_VEO3_MODEL") || "google/veo-3.1"

  defp hilua_slug,
    do:
      System.get_env("REPLICATE_HILUA_MODEL") ||
        System.get_env("REPLICATE_HAILUO_MODEL") || "minimax/hailuo-02"

  @version_cache_key {__MODULE__, :model_version}

  defp resolve_model_version(slug) do
    if String.contains?(slug, ":") do
      {:ok, slug}
    else
      cache_key = {@version_cache_key, slug}

      case :persistent_term.get(cache_key, :undefined) do
        :undefined ->
          case fetch_model_version(slug) do
            {:ok, version} ->
              :persistent_term.put(cache_key, version)
              {:ok, version}

            {:error, _} = error ->
              error
          end

        version ->
          {:ok, version}
      end
    end
  end

  defp fetch_model_version(slug) do
    api_key = get_api_key()

    headers = [
      {"Authorization", "Token #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{@base_url}/models/#{slug}"

    case Req.get(url, headers: headers, retry: :transient, max_retries: 3) do
      {:ok, %{status: status, body: %{"latest_version" => %{"id" => id}}}}
      when status in 200..299 ->
        {:ok, "#{slug}:#{id}"}

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[ReplicateService] Version lookup failed for #{slug}. Status: #{status}, Body: #{inspect(body)}"
        )

        {:error, {:version_lookup_failed, status, body}}

      {:error, reason} ->
        Logger.error(
          "[ReplicateService] Version lookup request failed for #{slug}: #{inspect(reason)}"
        )

        {:error, {:request_failed, reason}}
    end
  end

  defp build_veo_input(render_request, _config) do
    first = render_request.first_image_url
    last = render_request.last_image_url || first

    cond do
      not is_binary(first) ->
        {:error, :missing_first_frame}

      not is_binary(last) ->
        {:error, :missing_last_frame}

      true ->
        duration = veo_duration(render_request.duration)

        input = %{
          "prompt" => render_request.prompt,
          "image" => first,
          "last_frame" => last,
          "duration" => duration,
          "aspect_ratio" => normalize_aspect_ratio(render_request.aspect_ratio),
          "resolution" => "1080p",
          "generate_audio" => false
        }

        {:ok, input}
    end
  end

  defp build_hailuo_input(render_request, _config) do
    first = render_request.first_image_url
    last = render_request.last_image_url || first

    cond do
      not is_binary(first) ->
        {:error, :missing_first_frame}

      not is_binary(last) ->
        {:error, :missing_last_frame}

      true ->
        input = %{
          "first_frame_image" => first,
          "last_frame_image" => last,
          "duration" => hailuo_duration(render_request.duration),
          "resolution" => "1080p",
          "prompt_optimizer" => true,
          "prompt" => render_request.prompt
        }

        {:ok, input}
    end
  end

  defp veo_duration(duration) when is_number(duration) do
    cond do
      duration <= 5 -> 4
      duration <= 7 -> 6
      true -> 8
    end
  end

  defp veo_duration(_), do: 8

  defp hailuo_duration(duration) when is_number(duration) do
    if duration >= 9 do
      10
    else
      6
    end
  end

  defp hailuo_duration(_), do: 6

  defp normalize_aspect_ratio(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.replace(trimmed, ~r/\s+/, "") do
      "9:16" -> "9:16"
      "16:9" -> "16:9"
      "1:1" -> "1:1"
      _ -> "16:9"
    end
  end

  defp normalize_aspect_ratio(_), do: "16:9"

  defp maybe_attach_webhook(payload) do
    case Application.get_env(:backend, :replicate_webhook_url) do
      url when is_binary(url) and url != "" ->
        Map.put(payload, "webhook", url)

      _ ->
        payload
    end
  end
end
