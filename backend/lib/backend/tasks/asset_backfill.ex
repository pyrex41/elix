defmodule Backend.Tasks.AssetBackfill do
  @moduledoc """
  Utility task to backfill missing `blob_data` for assets that only have source URLs.

  Run inside a release with:

      bin/backend eval "Backend.Tasks.AssetBackfill.run()"

  Optional keyword opts:
    * `limit:` only process the first N assets
    * `sleep_ms:` delay between downloads (default 0)
  """
  require Logger
  import Ecto.Query

  alias Backend.Repo
  alias Backend.Schemas.Asset

  @default_headers [
    {"user-agent", "BackendAssetBackfill/1.0"}
  ]

  def run(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:backend)

    limit = Keyword.get(opts, :limit)
    sleep_ms = Keyword.get(opts, :sleep_ms, 0)

    query =
      Asset
      |> where([a], is_nil(a.blob_data))
      |> where([a], not is_nil(a.source_url) and a.source_url != "")
      |> order_by([a], asc: a.inserted_at)

    query =
      if is_integer(limit) and limit > 0 do
        limit(query, ^limit)
      else
        query
      end

    assets = Repo.all(query)
    total = length(assets)

    Logger.info("[AssetBackfill] Starting blob backfill for #{total} assets")

    results =
      assets
      |> Enum.with_index(1)
      |> Enum.map(fn {asset, index} ->
        maybe_sleep(sleep_ms)
        backfill_asset(asset, index, total)
      end)

    summary =
      Enum.reduce(results, %{ok: 0, skipped: 0, error: 0}, fn
        :ok, acc -> %{acc | ok: acc.ok + 1}
        :skipped, acc -> %{acc | skipped: acc.skipped + 1}
        :error, acc -> %{acc | error: acc.error + 1}
      end)

    Logger.info(
      "[AssetBackfill] Finished. Updated=#{summary.ok}, skipped=#{summary.skipped}, errors=#{summary.error}"
    )

    summary
  end

  defp maybe_sleep(ms) when is_integer(ms) and ms > 0 do
    Process.sleep(ms)
  end

  defp maybe_sleep(_), do: :ok

  defp backfill_asset(%Asset{} = asset, index, total) do
    Logger.info(
      "[AssetBackfill] (#{index}/#{total}) Downloading #{asset.id} from #{asset.source_url}"
    )

    case download(asset.source_url) do
      {:ok, body, content_type} ->
        metadata =
          (asset.metadata || %{})
          |> Map.put("original_content_type", content_type)
          |> Map.put("blob_backfilled_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put("blob_size_bytes", byte_size(body))

        case asset |> Asset.changeset(%{blob_data: body, metadata: metadata}) |> Repo.update() do
          {:ok, _} ->
            Logger.info("[AssetBackfill] Stored #{byte_size(body)} bytes for #{asset.id}")
            :ok

          {:error, changeset} ->
            Logger.error(
              "[AssetBackfill] Failed to update #{asset.id}: #{inspect(changeset.errors)}"
            )

            :error
        end

      {:error, {:http_status, status}} ->
        Logger.warning("[AssetBackfill] Skipping #{asset.id}, HTTP #{status}")
        :skipped

      {:error, reason} ->
        Logger.error("[AssetBackfill] Failed to download #{asset.id}: #{inspect(reason)}")
        :error
    end
  end

  defp download(url) do
    case Req.get(url, headers: @default_headers, redirect: :follow, max_redirects: 3) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        content_type =
          headers
          |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end)
          |> Map.get("content-type", "application/octet-stream")

        {:ok, body, content_type}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
