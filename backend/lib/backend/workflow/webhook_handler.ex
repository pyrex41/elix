defmodule Backend.Workflow.WebhookHandler do
  @moduledoc """
  Handles asynchronous callbacks from Replicate predictions.
  """
  require Logger

  alias Backend.Repo
  alias Backend.Schemas.SubJob
  alias Backend.Services.ReplicateService
  alias Backend.Workflow.{Coordinator, RenderWorker}

  @success_status "succeeded"

  @spec handle_event(map()) :: :ok | :error
  def handle_event(%{"id" => prediction_id} = payload) when is_binary(prediction_id) do
    case Repo.get_by(SubJob, provider_id: prediction_id) do
      nil ->
        Logger.warning("[WebhookHandler] No sub_job found for prediction #{prediction_id}")
        :ok

      sub_job ->
        process_status(sub_job, payload)
    end
  end

  def handle_event(payload) do
    Logger.error("[WebhookHandler] Missing prediction id in payload: #{inspect(payload)}")
    :error
  end

  defp process_status(sub_job, %{"status" => @success_status} = payload) do
    cond do
      sub_job.status == :completed ->
        Logger.info(
          "[WebhookHandler] Sub_job #{sub_job.id} already completed for prediction #{payload["id"]}"
        )

        :ok

      true ->
        with {:ok, prediction} <- ensure_prediction_payload(payload),
             {:ok, _updated} <- RenderWorker.complete_prediction(sub_job, prediction) do
          Coordinator.sub_job_completed(sub_job.job_id, sub_job.id)
          :ok
        else
          {:error, reason} ->
            Logger.error(
              "[WebhookHandler] Failed to finalize sub_job #{sub_job.id}: #{inspect(reason)}"
            )

            Coordinator.fail_job(sub_job.job_id, "Webhook completion failed for #{sub_job.id}")
            :error
        end
    end
  end

  defp process_status(sub_job, %{"status" => status} = payload)
       when status in ["failed", "canceled", "aborted"] do
    Logger.error(
      "[WebhookHandler] Prediction #{payload["id"]} #{status}; marking sub_job #{sub_job.id} failed"
    )

    _ = SubJob.status_changeset(sub_job, %{status: :failed}) |> Repo.update()
    Coordinator.fail_job(sub_job.job_id, "Prediction #{status}")
    :ok
  end

  defp process_status(_sub_job, payload) do
    Logger.debug(
      "[WebhookHandler] Ignoring webhook payload with status #{inspect(payload["status"])}"
    )

    :ok
  end

  defp ensure_prediction_payload(%{"output" => _} = payload), do: {:ok, payload}

  defp ensure_prediction_payload(%{"id" => prediction_id}) do
    ReplicateService.get_prediction(prediction_id)
  end
end
