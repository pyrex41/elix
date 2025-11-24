defmodule Backend.Services.CostEstimator do
  @moduledoc """
  Helper functions for estimating rendering costs based on model usage.

  Currently supports VEO-3.x style models and Hailuo 2.x variants with
  per-second pricing. Additional models fall back to zero cost until
  pricing details are provided.
  """

  @type scene :: map()

  @veo_price_per_second 0.20
  @hailuo_price_per_second 0.10
  @default_duration_seconds 6.0

  @doc """
  Estimate the total cost for a list of scenes.

  ## Options
    * `:default_model` - model to assume when a scene does not specify one
    * `:default_duration` - fallback duration (in seconds) when a scene
      omits the duration field
  """
  @spec estimate_job_cost([scene()], keyword()) :: float()
  def estimate_job_cost(scenes, opts \\ []) do
    default_model = Keyword.get(opts, :default_model)
    default_duration = Keyword.get(opts, :default_duration, @default_duration_seconds)

    scenes
    |> Enum.reduce(0.0, fn scene, acc ->
      model = scene_model(scene) || default_model
      duration = scene_duration(scene, default_duration)
      acc + duration * cost_per_second(model)
    end)
    |> Float.round(2)
  end

  @doc """
  Returns the price per second for a given model (downcased string).
  """
  @spec cost_per_second(String.t() | atom() | nil) :: float()
  def cost_per_second(nil), do: 0.0

  def cost_per_second(model) do
    case normalize_model(model) do
      "veo3" -> @veo_price_per_second
      "veo-3.1" -> @veo_price_per_second
      "google/veo-3.1" -> @veo_price_per_second
      "hailuo-2.3" -> @hailuo_price_per_second
      "hailuo-23" -> @hailuo_price_per_second
      "hailuo-2.5" -> @hailuo_price_per_second
      "hailuo-02" -> @hailuo_price_per_second
      "hilua-2.5" -> @hailuo_price_per_second
      _ -> 0.0
    end
  end

  defp scene_model(scene) when is_map(scene) do
    Map.get(scene, "model") ||
      Map.get(scene, :model)
  end

  defp scene_model(_), do: nil

  defp scene_duration(scene, default_duration) when is_map(scene) do
    case Map.get(scene, "duration") || Map.get(scene, :duration) do
      duration when is_integer(duration) -> duration * 1.0
      duration when is_float(duration) -> duration
      duration when is_binary(duration) -> parse_duration(duration, default_duration)
      _ -> default_duration || @default_duration_seconds
    end
  end

  defp scene_duration(_scene, default_duration) do
    default_duration || @default_duration_seconds
  end

  defp parse_duration(value, fallback) do
    case Float.parse(value) do
      {float_val, _} -> float_val
      :error -> fallback || @default_duration_seconds
    end
  end

  defp normalize_model(model) when is_atom(model) do
    model
    |> Atom.to_string()
    |> normalize_model()
  end

  defp normalize_model(model) when is_binary(model) do
    model
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_model(_), do: nil
end
