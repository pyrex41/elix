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
  alias Backend.Schemas.{Asset, Job, SubJob}
  alias Backend.Services.ReplicateService
  import Ecto.Query

  @default_max_concurrency 4
  @default_start_delay_ms 1_000

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

      # Process sub_jobs in parallel with staggered Replicate starts to avoid throttling
      max_concurrency = Map.get(options, :max_concurrency, configured_max_concurrency())
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

    with {:ok, context} <- load_scene_context(sub_job),
         {:ok, render_request} <- build_render_request(context),
         {:ok, prediction} <- start_rendering(render_request, options),
         {:ok, sub_job} <- ensure_provider_id(sub_job, prediction),
         {:ok, completed_prediction} <- poll_for_completion(prediction, options),
         {:ok, updated_sub_job} <- complete_prediction(sub_job, completed_prediction) do
      Logger.info("[RenderWorker] Successfully processed sub_job #{sub_job.id}")
      {:ok, updated_sub_job}
    else
      {:error, reason} = error ->
        Logger.error("[RenderWorker] Failed to process sub_job #{sub_job.id}: #{inspect(reason)}")

        update_sub_job_status(sub_job, :failed)
        error
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

  defp load_scene_context(sub_job) do
    case Repo.get(Job, sub_job.job_id) do
      nil ->
        Logger.error("[RenderWorker] Job #{sub_job.job_id} not found for sub_job #{sub_job.id}")
        {:error, :job_not_found}

      %Job{storyboard: nil} ->
        Logger.error("[RenderWorker] Job #{sub_job.job_id} has no storyboard data")
        {:error, :no_storyboard}

      %Job{} = job ->
        scenes = get_in(job.storyboard, ["scenes"]) || []
        sub_job_index = get_sub_job_index(job.id, sub_job.id)

        cond do
          scenes == [] ->
            Logger.error("[RenderWorker] Job #{job.id} storyboard has no scenes")
            {:error, :no_scenes}

          is_nil(sub_job_index) ->
            Logger.error(
              "[RenderWorker] Could not determine scene index for sub_job #{sub_job.id}"
            )

            {:error, :scene_index_not_found}

          true ->
            case Enum.fetch(scenes, sub_job_index) do
              {:ok, scene} when is_map(scene) ->
                {:ok,
                 %{
                   job: job,
                   scene: scene,
                   scene_index: sub_job_index,
                   params: normalize_param_keys(job.parameters || %{})
                 }}

              _ ->
                Logger.error(
                  "[RenderWorker] Scene not found at index #{sub_job_index} for job #{job.id}"
                )

                {:error, :scene_not_found}
            end
        end
    end
  end

  defp build_render_request(%{job: job, scene: scene, scene_index: index, params: params}) do
    with {:ok, asset_ctx} <- resolve_scene_assets(scene, job, params) do
      base_url = external_base_url()
      Logger.info("[RenderWorker] Using base URL: #{base_url}")
      first_url = build_asset_url(base_url, asset_ctx.first.id)
      last_url = build_asset_url(base_url, asset_ctx.last.id)
      Logger.info("[RenderWorker] Image URLs - first: #{first_url}, last: #{last_url}")

      model =
        scene["model"] ||
          scene[:model] ||
          params["video_model"] ||
          params["video_generation_model"] ||
          Application.get_env(:backend, :video_generation_model, "veo3")

      normalized_model =
        model
        |> to_string()
        |> String.downcase()

      render_request = %{
        model: normalized_model,
        prompt: scene_prompt(scene),
        duration: scene_duration(scene, params),
        aspect_ratio: scene_aspect_ratio(scene, params),
        first_image_url: first_url,
        last_image_url: last_url,
        metadata: %{
          title: scene["title"] || scene[:title],
          text_overlay: scene["text_overlay"] || scene[:text_overlay],
          scene_index: index,
          asset_ids: asset_ctx.ordered_ids,
          fallback_assets: Map.get(asset_ctx, :fallback?, false)
        }
      }

      log_scene_prompt(job, scene, index, render_request)

      {:ok, render_request}
    end
  end

  defp resolve_scene_assets(scene, job, params) do
    asset_ids = normalize_scene_asset_ids(scene)

    cond do
      asset_ids != [] ->
        assets =
          Asset
          |> where([a], a.id in ^asset_ids)
          |> Repo.all()

        asset_map = Map.new(assets, &{&1.id, &1})
        first_id = hd(asset_ids)
        last_id = List.last(asset_ids)

        with %Asset{} = first <- Map.get(asset_map, first_id),
             %Asset{} = last <- Map.get(asset_map, last_id) do
          {:ok,
           %{
             first: first,
             last: last,
             ordered_ids: asset_ids
           }}
        else
          _ ->
            Logger.error(
              "[RenderWorker] Asset references #{inspect(asset_ids)} missing for job #{job.id}"
            )

            {:error, :assets_not_found}
        end

      true ->
        load_fallback_assets(job, params)
    end
  end

  defp normalize_scene_asset_ids(scene) when is_map(scene) do
    cond do
      ids = Map.get(scene, "asset_ids") -> Enum.filter(ids || [], &is_binary/1)
      ids = Map.get(scene, :asset_ids) -> Enum.filter(ids || [], &is_binary/1)
      id = Map.get(scene, "asset_id") -> [id]
      id = Map.get(scene, :asset_id) -> [id]
      true -> []
    end
  end

  defp normalize_scene_asset_ids(_), do: []

  defp load_fallback_assets(job, params) do
    campaign_id =
      params["campaign_id"] ||
        params["campaignId"] ||
        params["client_campaign_id"]

    if is_binary(campaign_id) do
      assets =
        Asset
        |> where([a], a.campaign_id == ^campaign_id and a.type == ^:image)
        |> order_by([a], asc: a.inserted_at)
        |> limit(2)
        |> Repo.all()

      case assets do
        [] ->
          Logger.error(
            "[RenderWorker] No fallback assets found for campaign #{campaign_id} (job #{job.id})"
          )

          {:error, :fallback_assets_not_found}

        [single] ->
          {:ok,
           %{
             first: single,
             last: single,
             ordered_ids: [single.id],
             fallback?: true
           }}

        [_ | _] = list ->
          first = hd(list)
          last = List.last(list)

          {:ok,
           %{
             first: first,
             last: last,
             ordered_ids: Enum.map(list, & &1.id),
             fallback?: true
           }}
      end
    else
      Logger.error(
        "[RenderWorker] Scene is missing asset references and campaign_id could not be determined"
      )

      {:error, :missing_asset_ids}
    end
  end

  defp external_base_url do
    Application.get_env(:backend, :asset_base_url) ||
      Application.get_env(:backend, :public_base_url) ||
      BackendWeb.Endpoint.url()
  end

  defp build_asset_url(base, asset_id) do
    base
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v3/assets/#{asset_id}/data")
  end

  defp normalize_param_keys(params) when is_map(params) do
    Enum.reduce(params, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_param_keys(_), do: %{}

  defp log_scene_prompt(%Job{id: job_id, storyboard: storyboard}, scene, index, render_request) do
    scene_total =
      storyboard
      |> case do
        %{"scenes" => scenes} when is_list(scenes) -> length(scenes)
        %{scenes: scenes} when is_list(scenes) -> length(scenes)
        _ -> nil
      end

    scene_type =
      scene["scene_type"] ||
        scene[:scene_type] ||
        scene["title"] ||
        scene[:title] ||
        "unknown_scene"

    prompt_preview =
      render_request.prompt
      |> to_string()
      |> String.replace("\n", " ")
      |> String.trim()

    Logger.info(
      "[RenderWorker] Job #{job_id} scene #{index + 1}#{if scene_total, do: "/#{scene_total}", else: ""} (#{scene_type}) prompt: #{prompt_preview}"
    )
  end

  defp scene_prompt(scene) do
    scene["prompt"] ||
      scene[:prompt] ||
      scene["description"] ||
      scene[:description] ||
      scene["title"] ||
      scene[:title] ||
      "Smooth cinematic transition between key frames"
  end

  defp scene_duration(scene, params) do
    duration =
      scene["duration"] ||
        scene[:duration] ||
        params["clip_duration"] ||
        6

    cond do
      is_integer(duration) ->
        duration

      is_float(duration) ->
        duration

      is_binary(duration) ->
        case Float.parse(duration) do
          {value, _} -> value
          :error -> 6
        end

      true ->
        6
    end
  end

  defp scene_aspect_ratio(scene, params) do
    scene["aspect_ratio"] ||
      scene[:aspect_ratio] ||
      params["aspect_ratio"] ||
      "16:9"
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

  defp start_rendering(render_request, options) do
    maybe_throttle_prediction_start(render_request, options)

    Logger.info(
      "[RenderWorker] Starting render for scene #{render_request.metadata[:scene_index]} using model #{render_request.model}"
    )

    case ReplicateService.start_render(render_request, options) do
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

  defp ensure_provider_id(sub_job, prediction) do
    prediction_id = prediction_id(prediction)

    cond do
      is_nil(prediction_id) ->
        {:ok, sub_job}

      sub_job.provider_id == prediction_id ->
        {:ok, sub_job}

      true ->
        case SubJob.changeset(sub_job, %{provider_id: prediction_id}) |> Repo.update() do
          {:ok, updated} ->
            {:ok, updated}

          {:error, changeset} ->
            Logger.error(
              "[RenderWorker] Failed to persist provider id for sub_job #{sub_job.id}: #{inspect(changeset.errors)}"
            )

            {:error, :provider_update_failed}
        end
    end
  end

  def complete_prediction(sub_job, prediction) do
    with {:ok, _} <- ensure_provider_id(sub_job, prediction),
         {:ok, video_blob} <- download_video(prediction),
         {:ok, updated_sub_job} <-
           store_video_blob(sub_job, video_blob, prediction_id(prediction)) do
      {:ok, updated_sub_job}
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

  defp prediction_id(prediction) when is_map(prediction) do
    Map.get(prediction, "id") || Map.get(prediction, :id)
  end

  defp prediction_id(prediction) when is_struct(prediction) do
    Map.get(prediction, :id)
  end

  defp configured_max_concurrency do
    Application.get_env(:backend, :replicate_max_concurrency, @default_max_concurrency)
    |> max(1)
  end

  defp configured_start_delay_ms do
    Application.get_env(:backend, :replicate_start_delay_ms, @default_start_delay_ms)
    |> max(0)
  end

  defp maybe_throttle_prediction_start(render_request, options) do
    base_delay =
      Map.get(options, :start_delay_ms, configured_start_delay_ms())
      |> max(0)

    scene_index =
      render_request
      |> Map.get(:metadata)
      |> case do
        map when is_map(map) -> Map.get(map, :scene_index) || Map.get(map, "scene_index")
        _ -> nil
      end

    cond do
      base_delay <= 0 ->
        :ok

      is_integer(scene_index) and scene_index > 0 ->
        total_delay = scene_index * base_delay

        Logger.debug(
          "[RenderWorker] Delaying render start for scene #{scene_index} by #{total_delay}ms to stagger Replicate requests"
        )

        Process.sleep(total_delay)

      true ->
        :ok
    end
  end
end
