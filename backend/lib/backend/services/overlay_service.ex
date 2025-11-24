defmodule Backend.Services.OverlayService do
  @moduledoc """
  Service for adding overlays to videos using FFmpeg.

  Supports:
  - Text overlays with custom fonts, colors, and positioning
  - Animated text (fade in/out)
  - Multiple text layers
  - Future: Avatar overlays
  """
  require Logger

  @doc """
  Adds text overlay to a video.

  ## Parameters
    - video_blob: Binary video data
    - text: Text to overlay
    - options: Map with overlay options:
      - font: Font name (default: "Arial")
      - font_size: Font size (default: 48)
      - color: Text color (default: "white")
      - position: Position preset or custom coordinates
      - fade_in: Fade in duration in seconds (default: 0.5)
      - fade_out: Fade out duration in seconds (default: 0.5)
      - start_time: When to show text (default: 0)
      - duration: How long to show text (default: video duration)

  ## Returns
    - {:ok, video_blob_with_overlay} on success
    - {:error, reason} on failure
  """
  def add_text_overlay(video_blob, text, options \\ %{}) do
    Logger.info("[OverlayService] Adding text overlay: #{text}")

    temp_input = create_temp_file("input", ".mp4")
    temp_output = create_temp_file("output", ".mp4")

    try do
      File.write!(temp_input, video_blob)

      # Get video duration
      {:ok, duration} = get_video_duration(temp_input)

      # Build FFmpeg filter
      filter = build_text_filter(text, options, duration)

      # Build FFmpeg command
      args = [
        "-i",
        temp_input,
        "-vf",
        filter,
        "-c:v",
        "libx264",
        "-c:a",
        "copy",
        "-y",
        temp_output
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          output_blob = File.read!(temp_output)
          {:ok, output_blob}

        {output, exit_code} ->
          Logger.error("[OverlayService] FFmpeg failed (exit #{exit_code}): #{output}")
          {:error, "FFmpeg overlay failed"}
      end
    rescue
      e ->
        Logger.error("[OverlayService] Exception: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_input, temp_output])
    end
  end

  @doc """
  Adds multiple text overlays to a video in sequence.

  ## Parameters
    - video_blob: Binary video data
    - overlays: List of overlay specs, each with:
      - text: Text to display
      - start_time: When to show (seconds)
      - duration: How long to show (seconds)
      - options: Overlay options (font, color, position, etc.)

  ## Returns
    - {:ok, video_blob_with_overlays} on success
    - {:error, reason} on failure
  """
  def add_multiple_text_overlays(video_blob, overlays) when is_list(overlays) do
    Logger.info("[OverlayService] Adding #{length(overlays)} text overlays")

    temp_input = create_temp_file("input", ".mp4")
    temp_output = create_temp_file("output", ".mp4")

    try do
      File.write!(temp_input, video_blob)

      # Get video duration
      {:ok, duration} = get_video_duration(temp_input)

      # Build combined filter for all overlays
      filter = build_multiple_text_filters(overlays, duration)

      # Build FFmpeg command
      args = [
        "-i",
        temp_input,
        "-vf",
        filter,
        "-c:v",
        "libx264",
        "-c:a",
        "copy",
        "-y",
        temp_output
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          output_blob = File.read!(temp_output)
          {:ok, output_blob}

        {output, exit_code} ->
          Logger.error("[OverlayService] FFmpeg failed (exit #{exit_code}): #{output}")
          {:error, "FFmpeg overlay failed"}
      end
    rescue
      e ->
        Logger.error("[OverlayService] Exception: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      cleanup_temp_files([temp_input, temp_output])
    end
  end

  @doc """
  Generates a preview of text overlay settings.
  Returns information about how the overlay will look without processing video.
  """
  def preview_text_overlay(text, options \\ %{}) do
    %{
      text: text,
      font: Map.get(options, :font, "Arial"),
      font_size: Map.get(options, :font_size, 48),
      color: Map.get(options, :color, "white"),
      position: resolve_position(Map.get(options, :position, "bottom_center")),
      fade_in: Map.get(options, :fade_in, 0.5),
      fade_out: Map.get(options, :fade_out, 0.5),
      start_time: Map.get(options, :start_time, 0),
      duration: Map.get(options, :duration, nil)
    }
  end

  # Private helpers

  defp build_text_filter(text, options, video_duration) do
    # Extract options with defaults
    font = Map.get(options, :font, "Arial")
    font_size = Map.get(options, :font_size, 48)
    color = Map.get(options, :color, "white")
    position = resolve_position(Map.get(options, :position, "bottom_center"))
    fade_in = Map.get(options, :fade_in, 0.5)
    fade_out = Map.get(options, :fade_out, 0.5)
    start_time = Map.get(options, :start_time, 0)
    duration = Map.get(options, :duration, video_duration - start_time)

    # Escape text for FFmpeg
    escaped_text = escape_text(text)

    font_file = resolve_font_path(font)

    # Build drawtext filter
    base_filter =
      "drawtext=text='#{escaped_text}':fontfile=#{font_file}:fontsize=#{font_size}:fontcolor=#{color}:#{position}"

    # Add timing
    timing_filter = "#{base_filter}:enable='between(t,#{start_time},#{start_time + duration})'"

    # Add fade effects if requested
    if fade_in > 0 or fade_out > 0 do
      fade_filter = build_fade_expression(start_time, duration, fade_in, fade_out)
      "#{timing_filter}:alpha='#{fade_filter}'"
    else
      timing_filter
    end
  end

  defp build_multiple_text_filters(overlays, video_duration) do
    overlays
    |> Enum.map(fn overlay ->
      text = Map.get(overlay, "text") || Map.get(overlay, :text)
      start_time = Map.get(overlay, "start_time") || Map.get(overlay, :start_time, 0)

      duration =
        Map.get(overlay, "duration") || Map.get(overlay, :duration, video_duration - start_time)

      options = Map.get(overlay, "options") || Map.get(overlay, :options, %{})

      options_with_timing =
        options
        |> Map.put(:start_time, start_time)
        |> Map.put(:duration, duration)

      build_text_filter(text, options_with_timing, video_duration)
    end)
    |> Enum.join(",")
  end

  defp build_fade_expression(start_time, duration, fade_in, fade_out) do
    end_time = start_time + duration
    fade_out_start = end_time - fade_out

    cond do
      fade_in > 0 and fade_out > 0 ->
        "if(lt(t,#{start_time + fade_in}),(t-#{start_time})/#{fade_in},if(lt(t,#{fade_out_start}),1,(#{end_time}-t)/#{fade_out}))"

      fade_in > 0 ->
        "if(lt(t,#{start_time + fade_in}),(t-#{start_time})/#{fade_in},1)"

      fade_out > 0 ->
        "if(lt(t,#{fade_out_start}),1,(#{end_time}-t)/#{fade_out})"

      true ->
        "1"
    end
  end

  defp resolve_position(position) when is_binary(position) do
    case position do
      "top_left" -> "x=50:y=50"
      "top_center" -> "x=(w-text_w)/2:y=50"
      "top_right" -> "x=w-text_w-50:y=50"
      "center" -> "x=(w-text_w)/2:y=(h-text_h)/2"
      "bottom_left" -> "x=50:y=h-text_h-50"
      "bottom_center" -> "x=(w-text_w)/2:y=h-text_h-50"
      "bottom_right" -> "x=w-text_w-50:y=h-text_h-50"
      custom -> custom
    end
  end

  defp resolve_position(position) when is_map(position) do
    x = Map.get(position, :x, 0)
    y = Map.get(position, :y, 0)
    "x=#{x}:y=#{y}"
  end

  defp resolve_position(_), do: "x=(w-text_w)/2:y=h-text_h-50"

  defp resolve_font_path(font) when is_binary(font) do
    font_lower = String.downcase(font)

    case font_lower do
      "arial" -> "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
      "arial_bold" -> "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
      "opensans" -> "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
      _ -> "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    end
  end

  defp resolve_font_path(_), do: "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

  defp escape_text(text) do
    text
    |> String.replace("'", "\\'")
    |> String.replace(":", "\\:")
    |> String.replace("%", "\\%")
  end

  defp get_video_duration(file_path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      file_path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {duration, _} -> {:ok, duration}
          :error -> {:error, "Invalid duration format"}
        end

      {output, _} ->
        Logger.error("[OverlayService] ffprobe failed: #{output}")
        {:error, "Failed to get video duration"}
    end
  end

  defp create_temp_file(prefix, extension) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}#{extension}")
  end

  defp cleanup_temp_files(paths) do
    Enum.each(paths, fn path ->
      File.rm(path)
    end)
  end
end
