defmodule BackendWeb.Schemas.SceneSchemas do
  @moduledoc """
  OpenAPI schemas for Scene-related operations.
  """

  alias OpenApiSpex.Schema

  defmodule Scene do
    @moduledoc """
    Schema for a Scene resource.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Scene",
      description: "A scene in a video job",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Scene ID"},
        job_id: %Schema{type: :integer, description: "Associated job ID"},
        scene_number: %Schema{type: :integer, description: "Scene order number", minimum: 1},
        type: %Schema{
          type: :string,
          enum: [:transition, :showcase, :comparison, :highlight],
          description: "Scene type"
        },
        duration_seconds: %Schema{
          type: :number,
          description: "Scene duration in seconds",
          minimum: 0.5,
          maximum: 30
        },
        content: %Schema{
          type: :object,
          description: "Scene content configuration",
          properties: %{
            text: %Schema{type: :string, description: "Text overlay"},
            transition_type: %Schema{
              type: :string,
              enum: [:fade, :slide, :zoom, :wipe],
              description: "Transition type"
            },
            effects: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Visual effects to apply"
            }
          }
        },
        asset_ids: %Schema{
          type: :array,
          items: %Schema{type: :integer},
          description: "Asset IDs used in this scene"
        },
        render_status: %Schema{
          type: :string,
          enum: [:pending, :rendering, :completed, :failed],
          description: "Render status of this scene"
        },
        render_url: %Schema{
          type: :string,
          format: :uri,
          description: "URL to rendered scene video"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last update timestamp"
        }
      },
      required: [:id, :job_id, :scene_number, :type],
      example: %{
        "id" => 456,
        "job_id" => 123,
        "scene_number" => 1,
        "type" => "showcase",
        "duration_seconds" => 3.5,
        "content" => %{
          "text" => "Modern Kitchen",
          "transition_type" => "fade",
          "effects" => ["ken_burns", "vignette"]
        },
        "asset_ids" => [1, 2],
        "render_status" => "completed",
        "render_url" => "https://cdn.example.com/scenes/456.mp4",
        "inserted_at" => "2025-11-23T12:34:55Z",
        "updated_at" => "2025-11-23T12:35:30Z"
      }
    })
  end

  defmodule SceneCreateRequest do
    @moduledoc """
    Schema for scene creation request.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SceneCreateRequest",
      description: "Request to create a scene",
      type: :object,
      properties: %{
        scene_number: %Schema{type: :integer, description: "Scene order number", minimum: 1},
        type: %Schema{
          type: :string,
          enum: [:transition, :showcase, :comparison, :highlight],
          description: "Scene type"
        },
        duration_seconds: %Schema{
          type: :number,
          description: "Scene duration in seconds",
          minimum: 0.5,
          maximum: 30
        },
        content: %Schema{
          type: :object,
          description: "Scene content configuration",
          properties: %{
            text: %Schema{type: :string},
            transition_type: %Schema{
              type: :string,
              enum: [:fade, :slide, :zoom, :wipe]
            },
            effects: %Schema{
              type: :array,
              items: %Schema{type: :string}
            }
          }
        },
        asset_ids: %Schema{
          type: :array,
          items: %Schema{type: :integer},
          description: "Asset IDs to use in this scene"
        }
      },
      required: [:scene_number, :type],
      example: %{
        "scene_number" => 1,
        "type" => "showcase",
        "duration_seconds" => 3.5,
        "content" => %{
          "text" => "Modern Kitchen",
          "transition_type" => "fade",
          "effects" => ["ken_burns", "vignette"]
        },
        "asset_ids" => [1, 2]
      }
    })
  end

  defmodule SceneUpdateRequest do
    @moduledoc """
    Schema for scene update request.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SceneUpdateRequest",
      description: "Request to update a scene",
      type: :object,
      properties: %{
        scene_number: %Schema{type: :integer, minimum: 1},
        type: %Schema{
          type: :string,
          enum: [:transition, :showcase, :comparison, :highlight]
        },
        duration_seconds: %Schema{
          type: :number,
          minimum: 0.5,
          maximum: 30
        },
        content: %Schema{
          type: :object,
          properties: %{
            text: %Schema{type: :string},
            transition_type: %Schema{
              type: :string,
              enum: [:fade, :slide, :zoom, :wipe]
            },
            effects: %Schema{
              type: :array,
              items: %Schema{type: :string}
            }
          }
        },
        asset_ids: %Schema{
          type: :array,
          items: %Schema{type: :integer}
        }
      },
      example: %{
        "duration_seconds" => 4.0,
        "content" => %{
          "text" => "Renovated Kitchen",
          "effects" => ["ken_burns", "vignette", "color_grade"]
        }
      }
    })
  end

  defmodule SceneResponse do
    @moduledoc """
    Schema for scene response.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SceneResponse",
      description: "Response containing a scene",
      type: :object,
      properties: %{
        data: Scene
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => 456,
          "job_id" => 123,
          "scene_number" => 1,
          "type" => "showcase",
          "duration_seconds" => 3.5,
          "content" => %{
            "text" => "Modern Kitchen",
            "transition_type" => "fade",
            "effects" => ["ken_burns", "vignette"]
          },
          "asset_ids" => [1, 2],
          "render_status" => "completed",
          "render_url" => "https://cdn.example.com/scenes/456.mp4",
          "inserted_at" => "2025-11-23T12:34:55Z",
          "updated_at" => "2025-11-23T12:35:30Z"
        }
      }
    })
  end

  defmodule ScenesListResponse do
    @moduledoc """
    Schema for scenes list response.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ScenesListResponse",
      description: "Response containing a list of scenes",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: Scene
        },
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer},
            total_duration_seconds: %Schema{type: :number}
          }
        }
      },
      required: [:data],
      example: %{
        "data" => [
          %{
            "id" => 456,
            "job_id" => 123,
            "scene_number" => 1,
            "type" => "showcase",
            "duration_seconds" => 3.5,
            "render_status" => "completed"
          },
          %{
            "id" => 457,
            "job_id" => 123,
            "scene_number" => 2,
            "type" => "transition",
            "duration_seconds" => 1.0,
            "render_status" => "completed"
          }
        ],
        "meta" => %{
          "total" => 2,
          "total_duration_seconds" => 4.5
        }
      }
    })
  end
end