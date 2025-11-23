defmodule Backend.Pipeline.PipelineConfig do
  @moduledoc """
  Configuration system for video generation pipeline steps.

  Allows enabling/disabling different pipeline components:
  - Scene generation
  - Image selection
  - Video rendering
  - Text overlays
  - Voiceovers
  - Avatar overlays
  - Music generation
  - Video stitching
  """
  use Agent
  require Logger

  @default_config %{
    # Core pipeline steps
    scene_generation: %{
      enabled: true,
      use_ai: true,
      default_scene_count: 7
    },
    image_selection: %{
      enabled: true,
      use_llm: true,
      fallback_to_simple: true
    },
    video_rendering: %{
      enabled: true,
      model: "veo3",
      max_concurrency: 10
    },

    # Enhancement steps
    text_overlays: %{
      enabled: false,
      default_font: "Arial",
      default_font_size: 48,
      default_position: "bottom_center",
      default_color: "white",
      fade_in_duration: 0.5,
      fade_out_duration: 0.5
    },
    voiceover: %{
      enabled: false,
      tts_provider: "elevenlabs",
      # Options: elevenlabs, openai, google, aws_polly
      default_voice: "professional",
      generate_script: true,
      script_llm: "grok-4-1-fast-non-reasoning"
    },
    avatar_overlay: %{
      enabled: false,
      # Stub for future implementation
      avatar_type: "talking_head",
      position: "bottom_right",
      size: "small"
    },
    music_generation: %{
      enabled: true,
      use_continuation: true,
      default_duration: 4.0,
      fade_duration: 1.5
    },
    video_stitching: %{
      enabled: true,
      output_format: "mp4",
      merge_audio: true
    }
  }

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> load_config() end, name: __MODULE__)
  end

  @doc """
  Gets the current pipeline configuration.
  """
  def get_config do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Gets configuration for a specific pipeline step.
  """
  def get_step_config(step) when is_atom(step) do
    Agent.get(__MODULE__, fn config -> Map.get(config, step) end)
  end

  @doc """
  Checks if a pipeline step is enabled.
  """
  def step_enabled?(step) when is_atom(step) do
    case get_step_config(step) do
      %{enabled: enabled} -> enabled
      _ -> false
    end
  end

  @doc """
  Updates the pipeline configuration.
  Returns {:ok, new_config} or {:error, reason}.
  """
  def update_config(updates) when is_map(updates) do
    Agent.get_and_update(__MODULE__, fn current_config ->
      new_config = deep_merge(current_config, updates)
      Logger.info("[PipelineConfig] Configuration updated: #{inspect(updates)}")
      {{:ok, new_config}, new_config}
    end)
  end

  @doc """
  Updates a specific step's configuration.
  """
  def update_step(step, updates) when is_atom(step) and is_map(updates) do
    Agent.get_and_update(__MODULE__, fn current_config ->
      case Map.get(current_config, step) do
        nil ->
          {{:error, "Step #{step} not found"}, current_config}

        step_config ->
          updated_step = Map.merge(step_config, updates)
          new_config = Map.put(current_config, step, updated_step)
          Logger.info("[PipelineConfig] Step #{step} updated: #{inspect(updates)}")
          {{:ok, updated_step}, new_config}
      end
    end)
  end

  @doc """
  Enables a pipeline step.
  """
  def enable_step(step) when is_atom(step) do
    update_step(step, %{enabled: true})
  end

  @doc """
  Disables a pipeline step.
  """
  def disable_step(step) when is_atom(step) do
    update_step(step, %{enabled: false})
  end

  @doc """
  Resets configuration to defaults.
  """
  def reset_to_defaults do
    Agent.update(__MODULE__, fn _current ->
      Logger.info("[PipelineConfig] Configuration reset to defaults")
      @default_config
    end)

    {:ok, @default_config}
  end

  @doc """
  Persists current configuration to disk (optional).
  """
  def save_config do
    config = get_config()
    config_path = get_config_path()

    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        case File.write(config_path, json) do
          :ok ->
            Logger.info("[PipelineConfig] Configuration saved to #{config_path}")
            {:ok, config_path}

          {:error, reason} ->
            Logger.error("[PipelineConfig] Failed to save config: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Loads configuration from disk if available.
  """
  def load_config do
    config_path = get_config_path()

    if File.exists?(config_path) do
      case File.read(config_path) do
        {:ok, json} ->
          case Jason.decode(json, keys: :atoms) do
            {:ok, config} ->
              Logger.info("[PipelineConfig] Loaded configuration from #{config_path}")
              deep_merge(@default_config, config)

            {:error, reason} ->
              Logger.error("[PipelineConfig] Failed to parse config: #{inspect(reason)}")
              @default_config
          end

        {:error, reason} ->
          Logger.error("[PipelineConfig] Failed to read config: #{inspect(reason)}")
          @default_config
      end
    else
      Logger.info("[PipelineConfig] No saved config found, using defaults")
      @default_config
    end
  end

  # Private helpers

  defp get_config_path do
    config_dir = Application.get_env(:backend, :pipeline_config_dir, "priv/config")
    Path.join(config_dir, "pipeline_config.json")
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end
end
