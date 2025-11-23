defmodule Backend.Templates.SceneTemplates do
  @moduledoc """
  Defines standard scene templates for luxury property video generation.

  These templates provide consistent prompting strategies across different properties
  while maintaining flexibility for adaptation based on available assets.

  Each template includes:
  - Scene type identifier
  - Timing and duration defaults
  - Motion goals and camera movements
  - Video generation prompts
  - Asset selection criteria
  - Music generation guidance
  """

  @scene_templates %{
    hook: %{
      type: :hook,
      order: 1,
      title: "The Hook",
      subtitle: "Exterior Feature",
      time_start: 0.0,
      time_end: 1.5,
      default_duration: 1.5,

      # Asset selection criteria
      asset_criteria: %{
        scene_types: ["exterior", "pool", "courtyard", "terrace", "water_feature"],
        keywords: ["pool", "water", "exterior", "courtyard", "terrace", "garden"],
        preferred_tags: ["main_exterior", "hero_shot", "water"],
        requires_pairs: true
      },

      # Motion and cinematography
      motion_goal: "Immediate visual interest with subtle water or surface movement + gentle forward motion",
      camera_movement: "dolly_forward",

      # Video generation prompt
      video_prompt: """
      Cinematic wide shot, low angle. Clear water or reflective surface gently rippling.
      Subtle, smooth camera push-in (dolly forward). Bright natural lighting with glistening
      highlights on the water/surface. Photorealistic 4K, high fidelity, sharp focus on the
      edge detail.
      """,

      # Music generation guidance
      music_description: "Opening cinematic impact with subtle water ambience",
      music_style: "cinematic, ambient, uplifting",
      music_energy: "medium-high"
    },

    bedroom: %{
      type: :bedroom,
      order: 2,
      title: "The Hero Bedroom",
      subtitle: "Parallax",
      time_start: 1.5,
      time_end: 2.5,
      default_duration: 1.0,

      asset_criteria: %{
        scene_types: ["bedroom", "master_bedroom", "suite"],
        keywords: ["bedroom", "bed", "master", "suite", "sleeping"],
        preferred_tags: ["master_bedroom", "hero_bedroom", "primary_suite"],
        requires_pairs: true
      },

      motion_goal: "Lateral movement to reveal depth between foreground and background",
      camera_movement: "truck_lateral",

      video_prompt: """
      Smooth sideways camera truck (left or right – choose direction that creates natural parallax).
      Luxurious bedroom with large windows or glass walls. Parallax effect: bed and foreground
      elements move slightly faster than the background view. Soft natural light, no zoom,
      pure linear sideways motion.
      """,

      music_description: "Smooth transition with luxurious, serene tones",
      music_style: "elegant, serene, sophisticated",
      music_energy: "medium"
    },

    vanity: %{
      type: :vanity,
      order: 3,
      title: "Bathroom Vanity",
      subtitle: "Symmetry",
      time_start: 2.5,
      time_end: 3.5,
      default_duration: 1.0,

      asset_criteria: %{
        scene_types: ["bathroom", "vanity", "powder_room"],
        keywords: ["vanity", "bathroom", "mirror", "sink", "powder room"],
        preferred_tags: ["double_vanity", "master_bath", "ensuite"],
        requires_pairs: true
      },

      motion_goal: "Smooth sliding movement (opposite direction to Scene 2 for flow)",
      camera_movement: "truck_lateral_opposite",

      video_prompt: """
      Cinematic sideways truck (left or right – opposite of previous scene). Modern bathroom
      vanity with mirror. Reflections shift naturally as camera moves. Clean, bright lighting,
      sharp focus on surfaces and fixtures.
      """,

      music_description: "Clean, crisp tones maintaining elegant flow",
      music_style: "modern, clean, refined",
      music_energy: "medium"
    },

    tub: %{
      type: :tub,
      order: 4,
      title: "The Feature Tub",
      subtitle: "Depth",
      time_start: 3.5,
      time_end: 4.5,
      default_duration: 1.0,

      asset_criteria: %{
        scene_types: ["bathroom", "bathtub", "shower", "spa"],
        keywords: ["tub", "bathtub", "shower", "spa", "soaking"],
        preferred_tags: ["freestanding_tub", "feature_bath", "spa_bathroom"],
        requires_pairs: true
      },

      motion_goal: "Intimate push-in to emphasize the luxury fixture",
      camera_movement: "dolly_forward",

      video_prompt: """
      Slow, smooth dolly forward toward the centerpiece tub or shower. Background view through
      window or opening remains steady. Serene spa-like atmosphere, soft balanced lighting,
      high detail on textures and materials.
      """,

      music_description: "Intimate, spa-like atmosphere with gentle progression",
      music_style: "serene, spa, tranquil",
      music_energy: "low-medium"
    },

    living_room: %{
      type: :living_room,
      order: 5,
      title: "Living Room",
      subtitle: "The Sweep",
      time_start: 4.5,
      time_end: 5.5,
      default_duration: 1.0,

      asset_criteria: %{
        scene_types: ["living_room", "great_room", "lounge", "sitting_area"],
        keywords: ["living", "lounge", "sitting", "seating", "sofa", "great room"],
        preferred_tags: ["main_living", "great_room", "open_concept"],
        requires_pairs: true
      },

      motion_goal: "Sweeping movement to reveal scale and flow of the space",
      camera_movement: "pan_sweep",

      video_prompt: """
      Wide shot, smooth sideways pan or truck (choose direction that follows the natural lines
      of furniture/layout). Spacious living room with prominent seating. Natural light streaming
      in, subtle atmospheric particles in the air. Fluid, steady camera motion.
      """,

      music_description: "Expansive, flowing movement showcasing space",
      music_style: "open, airy, sophisticated",
      music_energy: "medium"
    },

    dining: %{
      type: :dining,
      order: 6,
      title: "Lifestyle / Dining Area",
      subtitle: "Atmosphere",
      time_start: 5.5,
      time_end: 6.5,
      default_duration: 1.0,

      asset_criteria: %{
        scene_types: ["dining", "dining_room", "outdoor_dining", "lifestyle"],
        keywords: ["dining", "table", "eating", "kitchen table", "outdoor dining"],
        preferred_tags: ["formal_dining", "outdoor_living", "lifestyle"],
        requires_pairs: true
      },

      motion_goal: "Near-static shot that lets the lighting and ambiance breathe",
      camera_movement: "static_float",

      video_prompt: """
      Almost static tripod shot with very subtle handheld float or gentle drift. Elegant dining
      or lifestyle area. Warm, inviting lighting. Minimal natural movement (candles, slight
      breeze, or soft fabric sway if present).
      """,

      music_description: "Warm, inviting atmosphere with subtle movement",
      music_style: "warm, inviting, intimate",
      music_energy: "medium-low"
    },

    outro: %{
      type: :outro,
      order: 7,
      title: "The Outro",
      subtitle: "Establishing Wide",
      time_start: 6.5,
      time_end: 10.0,
      default_duration: 3.5,

      asset_criteria: %{
        scene_types: ["exterior", "establishing", "wide_shot", "aerial", "entrance"],
        keywords: ["exterior", "wide", "establishing", "aerial", "entrance", "deck", "view"],
        preferred_tags: ["hero_exterior", "establishing_shot", "signature_view"],
        requires_pairs: true
      },

      motion_goal: "Gentle pull-back to leave the viewer with a lasting impression",
      camera_movement: "dolly_backward",

      video_prompt: """
      Smooth dolly outward or subtle drone-style pull-back. Establishing shot of the property
      at its most inviting time of day. Warm interior glow visible through windows (if applicable).
      Calm, cinematic, and peaceful closing moment.
      """,

      music_description: "Cinematic conclusion with peaceful resolution",
      music_style: "cinematic, peaceful, resolving",
      music_energy: "medium-low"
    }
  }

  @doc """
  Returns all scene templates in order.
  """
  def all_templates do
    @scene_templates
    |> Map.values()
    |> Enum.sort_by(& &1.order)
  end

  @doc """
  Returns a specific scene template by type.
  """
  def get_template(type) when is_atom(type) do
    Map.get(@scene_templates, type)
  end

  def get_template(type) when is_binary(type) do
    get_template(String.to_existing_atom(type))
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns scene templates matching specific criteria.
  Useful for filtering by indoor/outdoor or other characteristics.
  """
  def filter_templates(opts \\ []) do
    templates = all_templates()

    templates
    |> maybe_filter_by_indoor_outdoor(opts[:location])
    |> maybe_filter_by_camera_movement(opts[:camera_movement])
    |> maybe_filter_by_energy(opts[:energy])
  end

  defp maybe_filter_by_indoor_outdoor(templates, nil), do: templates
  defp maybe_filter_by_indoor_outdoor(templates, :outdoor) do
    Enum.filter(templates, fn t -> t.type in [:hook, :outro, :dining] end)
  end
  defp maybe_filter_by_indoor_outdoor(templates, :indoor) do
    Enum.filter(templates, fn t -> t.type in [:bedroom, :vanity, :tub, :living_room] end)
  end

  defp maybe_filter_by_camera_movement(templates, nil), do: templates
  defp maybe_filter_by_camera_movement(templates, movement) do
    Enum.filter(templates, fn t -> t.camera_movement == movement end)
  end

  defp maybe_filter_by_energy(templates, nil), do: templates
  defp maybe_filter_by_energy(templates, energy) do
    Enum.filter(templates, fn t -> t.music_energy == energy end)
  end

  @doc """
  Adapts scene templates to a specific number of scenes.

  Strategy:
  - Always include hook (scene 1) and outro (last scene)
  - For 3-6 scenes: Select from middle scenes based on available assets
  - Prioritize: bedroom > living_room > bathroom scenes
  """
  def adapt_to_scene_count(count, available_scene_types \\ []) when count >= 2 do
    templates = all_templates()

    # Always include hook and outro
    hook = Enum.find(templates, &(&1.type == :hook))
    outro = Enum.find(templates, &(&1.type == :outro))

    # Get middle scenes (priority order)
    middle_scenes =
      templates
      |> Enum.reject(&(&1.type in [:hook, :outro]))
      |> Enum.sort_by(&get_priority(&1.type))

    # Filter by available scene types if provided
    middle_scenes = if available_scene_types != [] do
      Enum.filter(middle_scenes, fn scene ->
        Enum.any?(scene.asset_criteria.scene_types, fn st ->
          st in available_scene_types
        end)
      end)
    else
      middle_scenes
    end

    # Select appropriate number of middle scenes
    selected_middle = Enum.take(middle_scenes, count - 2)

    # Reconstruct with adjusted timing
    scenes = [hook | selected_middle] ++ [outro]
    adjust_scene_timing(scenes)
  end

  # Priority for scene selection (lower = higher priority)
  defp get_priority(:bedroom), do: 1
  defp get_priority(:living_room), do: 2
  defp get_priority(:vanity), do: 3
  defp get_priority(:tub), do: 4
  defp get_priority(:dining), do: 5
  defp get_priority(_), do: 99

  @doc """
  Adjusts scene timing to fit a target total duration.
  Distributes time proportionally while respecting minimum durations.
  """
  def adjust_scene_timing(scenes, target_duration \\ 10.0) do
    total_min_duration = Enum.sum(Enum.map(scenes, & &1.default_duration))

    scenes
    |> Enum.with_index()
    |> Enum.map(fn {scene, idx} ->
      # Calculate proportional duration
      duration = (scene.default_duration / total_min_duration) * target_duration

      # Calculate start/end times
      start_time =
        scenes
        |> Enum.take(idx)
        |> Enum.sum(& &1.default_duration)
        |> Kernel.*(target_duration / total_min_duration)

      end_time = start_time + duration

      scene
      |> Map.put(:time_start, Float.round(start_time, 2))
      |> Map.put(:time_end, Float.round(end_time, 2))
      |> Map.put(:duration, Float.round(duration, 2))
    end)
  end

  @doc """
  Generates a music prompt based on scene characteristics.
  This can be used to create cohesive audio that matches the visual narrative.
  """
  def generate_music_prompt(scene_template, opts \\ []) do
    base_style = opts[:base_style] || "luxury real estate showcase"

    """
    #{base_style} - #{scene_template.music_description}.
    Style: #{scene_template.music_style}.
    Energy level: #{scene_template.music_energy}.
    Duration: #{scene_template.default_duration} seconds.
    """
    |> String.trim()
  end

  @doc """
  Returns asset selection criteria for LMM-based image selection.
  """
  def get_selection_criteria(scene_type) do
    case get_template(scene_type) do
      nil -> nil
      template -> template.asset_criteria
    end
  end
end
