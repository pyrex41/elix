defmodule Backend.Repo.Migrations.BackfillStoryboardAssetIds do
  use Ecto.Migration
  require Logger

  @doc """
  Backfills asset_ids in storyboard scenes for existing jobs that are missing them.
  This matches assets to scenes based on scene_type and asset tags/names.
  """
  def up do
    # Get all jobs with storyboards that have scenes
    jobs_query = """
    SELECT j.id, j.storyboard, j.parameters
    FROM jobs j
    WHERE j.storyboard IS NOT NULL
      AND json_extract(j.storyboard, '$.scenes') IS NOT NULL
      AND json_array_length(json_extract(j.storyboard, '$.scenes')) > 0
    """

    {:ok, result} = repo().query(jobs_query)

    jobs = Enum.map(result.rows, fn [id, storyboard_json, params_json] ->
      storyboard = if is_binary(storyboard_json), do: Jason.decode!(storyboard_json), else: storyboard_json
      params = if is_binary(params_json), do: Jason.decode!(params_json), else: params_json
      %{id: id, storyboard: storyboard, parameters: params}
    end)

    Logger.info("[Migration] Found #{length(jobs)} jobs to check for asset_ids backfill")

    Enum.each(jobs, fn job ->
      scenes = job.storyboard["scenes"] || []
      campaign_id = job.parameters["campaign_id"]

      # Check if any scene is missing asset_ids
      needs_backfill = Enum.any?(scenes, fn scene ->
        asset_ids = scene["asset_ids"]
        is_nil(asset_ids) or asset_ids == []
      end)

      if needs_backfill and campaign_id do
        Logger.info("[Migration] Backfilling asset_ids for job #{job.id}")
        backfill_job_assets(job.id, scenes, campaign_id)
      end
    end)

    Logger.info("[Migration] Completed asset_ids backfill")
  end

  def down do
    # This migration is not reversible as we're adding data
    # To reverse, you would need to remove asset_ids from all scenes
    :ok
  end

  defp backfill_job_assets(job_id, scenes, campaign_id) do
    # Get assets for this campaign
    assets_query = """
    SELECT id, name, tags FROM assets WHERE campaign_id = ?
    """

    case repo().query(assets_query, [campaign_id]) do
      {:ok, %{rows: asset_rows}} when length(asset_rows) > 0 ->
        assets = Enum.map(asset_rows, fn [id, name, tags_json] ->
          tags = case tags_json do
            nil -> []
            json when is_binary(json) -> Jason.decode!(json) |> List.wrap()
            list when is_list(list) -> list
            _ -> []
          end
          %{id: id, name: name, tags: tags}
        end)

        # Group assets by category
        grouped_assets = group_assets_by_category(assets)

        # Update each scene with asset_ids
        updated_scenes = scenes
        |> Enum.with_index()
        |> Enum.map(fn {scene, index} ->
          if has_asset_ids?(scene) do
            scene
          else
            scene_type = scene["scene_type"] || "general"
            matching_assets = find_matching_assets(scene_type, grouped_assets, assets, index)

            case matching_assets do
              [first | rest] ->
                last = List.last(rest) || first
                Map.put(scene, "asset_ids", [first.id, last.id])

              [] ->
                fallback_assets = get_fallback_assets(assets, index)
                Map.put(scene, "asset_ids", Enum.map(fallback_assets, & &1.id))
            end
          end
        end)

        # Calculate total duration
        total_duration = Enum.reduce(updated_scenes, 0.0, fn scene, acc ->
          duration = scene["duration"] || 4.0
          acc + (if is_number(duration), do: duration, else: 0.0)
        end)

        updated_storyboard = %{
          "scenes" => updated_scenes,
          "total_duration" => total_duration
        }

        # Update the job
        update_query = """
        UPDATE jobs SET storyboard = ? WHERE id = ?
        """

        repo().query(update_query, [Jason.encode!(updated_storyboard), job_id])
        Logger.info("[Migration] Updated job #{job_id} with asset_ids")

      _ ->
        Logger.warning("[Migration] No assets found for campaign #{campaign_id}, skipping job #{job_id}")
    end
  end

  defp has_asset_ids?(scene) do
    asset_ids = scene["asset_ids"]
    is_list(asset_ids) and length(asset_ids) > 0
  end

  defp group_assets_by_category(assets) do
    Enum.group_by(assets, fn asset ->
      cond do
        is_list(asset.tags) and asset.tags != [] ->
          asset.tags |> List.first() |> normalize_category()

        is_binary(asset.name) and asset.name != "" ->
          normalize_category(asset.name)

        true ->
          "general"
      end
    end)
  end

  defp normalize_category(nil), do: "general"

  defp normalize_category(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[_\s]+\d+$/, "")
    |> String.replace(~r/[_\s]+/, "_")
    |> String.trim()
  end

  defp find_matching_assets(scene_type, grouped_assets, all_assets, scene_index) do
    normalized_type = normalize_category(scene_type)

    exact_match = Map.get(grouped_assets, normalized_type, [])

    if length(exact_match) >= 2 do
      Enum.take(exact_match, 2)
    else
      partial_matches =
        grouped_assets
        |> Enum.filter(fn {category, _} ->
          String.contains?(category, normalized_type) or
            String.contains?(normalized_type, category)
        end)
        |> Enum.flat_map(fn {_, assets} -> assets end)

      if length(partial_matches) >= 2 do
        Enum.take(partial_matches, 2)
      else
        get_fallback_assets(all_assets, scene_index)
      end
    end
  end

  defp get_fallback_assets(assets, index) do
    asset_count = length(assets)

    if asset_count == 0 do
      []
    else
      first_idx = rem(index * 2, asset_count)
      second_idx = rem(index * 2 + 1, asset_count)

      first = Enum.at(assets, first_idx)
      second = Enum.at(assets, second_idx) || first

      [first, second] |> Enum.reject(&is_nil/1)
    end
  end
end
