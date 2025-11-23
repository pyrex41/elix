defmodule BackendWeb.Schemas.JobSchemas do
  @moduledoc """
  OpenAPI schemas for Job-related requests and responses
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule Job do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Job",
      description: "A job entity for video generation",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Job ID"},
        type: %Schema{
          type: :string,
          enum: ["image_pairs", "property_photos"],
          description: "Job type"
        },
        status: %Schema{
          type: :string,
          enum: ["pending", "approved", "processing", "completed", "failed"],
          description: "Job status"
        },
        parameters: %Schema{type: :object, description: "Job parameters", nullable: true},
        storyboard: %Schema{type: :object, description: "Generated storyboard", nullable: true},
        progress: %Schema{type: :object, description: "Job progress information", nullable: true},
        inserted_at: %Schema{
          type: :string,
          format: :datetime,
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          format: :datetime,
          description: "Last update timestamp"
        }
      },
      required: [:id, :type, :status],
      example: %{
        "id" => 123,
        "type" => "image_pairs",
        "status" => "pending",
        "parameters" => %{"duration" => 30},
        "storyboard" => %{
          "scenes" => [
            %{
              "scene_number" => 1,
              "description" => "Opening scene with product showcase"
            }
          ]
        },
        "progress" => %{"completed_scenes" => 0, "total_scenes" => 5},
        "inserted_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z"
      }
    })
  end

  defmodule ImagePairsRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ImagePairsRequest",
      description: "Request body for creating a job from image pairs",
      type: :object,
      properties: %{
        image_pairs: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              before: %Schema{type: :string, description: "Before image URL or data"},
              after: %Schema{type: :string, description: "After image URL or data"}
            }
          },
          description: "Array of before/after image pairs"
        },
        parameters: %Schema{type: :object, description: "Additional job parameters"}
      },
      required: [:image_pairs],
      example: %{
        "image_pairs" => [
          %{
            "before" => "https://example.com/before1.jpg",
            "after" => "https://example.com/after1.jpg"
          }
        ],
        "parameters" => %{"duration" => 30}
      }
    })
  end

  defmodule PropertyPhotosRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "PropertyPhotosRequest",
      description: "Request body for creating a job from property photos",
      type: :object,
      properties: %{
        photos: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Array of property photo URLs"
        },
        parameters: %Schema{type: :object, description: "Additional job parameters"}
      },
      required: [:photos],
      example: %{
        "photos" => [
          "https://example.com/photo1.jpg",
          "https://example.com/photo2.jpg"
        ],
        "parameters" => %{"duration" => 45}
      }
    })
  end

  defmodule JobResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "JobResponse",
      description: "Response containing a single job",
      type: :object,
      properties: %{
        data: Job
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => 123,
          "type" => "image_pairs",
          "status" => "pending",
          "parameters" => %{"duration" => 30},
          "storyboard" => %{
            "scenes" => [
              %{
                "scene_number" => 1,
                "description" => "Opening scene with product showcase"
              }
            ]
          },
          "progress" => %{"completed_scenes" => 0, "total_scenes" => 5},
          "inserted_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule Scene do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Scene",
      description: "A scene within a job's storyboard",
      type: :object,
      properties: %{
        scene_number: %Schema{type: :integer, description: "Scene number"},
        description: %Schema{type: :string, description: "Scene description"},
        prompt: %Schema{type: :string, description: "Generation prompt", nullable: true},
        image_url: %Schema{type: :string, description: "Generated image URL", nullable: true},
        status: %Schema{
          type: :string,
          enum: ["pending", "generating", "completed", "failed"],
          description: "Scene status"
        }
      },
      example: %{
        "scene_number" => 1,
        "description" => "Opening scene with product showcase",
        "prompt" => "A beautiful product display with soft lighting",
        "image_url" => "https://example.com/scene1.jpg",
        "status" => "completed"
      }
    })
  end

  defmodule SceneRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "SceneRequest",
      description: "Request body for updating a scene",
      type: :object,
      properties: %{
        description: %Schema{type: :string, description: "Scene description"},
        prompt: %Schema{type: :string, description: "Generation prompt"}
      },
      example: %{
        "description" => "Updated scene description",
        "prompt" => "A revised prompt for image generation"
      }
    })
  end

  defmodule ScenesResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ScenesResponse",
      description: "Response containing a list of scenes",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Scene}
      },
      required: [:data],
      example: %{
        "data" => [
          %{
            "scene_number" => 1,
            "description" => "Opening scene with product showcase",
            "prompt" => "A beautiful product display with soft lighting",
            "image_url" => "https://example.com/scene1.jpg",
            "status" => "completed"
          }
        ]
      }
    })
  end

  defmodule SceneResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "SceneResponse",
      description: "Response containing a single scene",
      type: :object,
      properties: %{
        data: Scene
      },
      required: [:data],
      example: %{
        "data" => %{
          "scene_number" => 1,
          "description" => "Opening scene with product showcase",
          "prompt" => "A beautiful product display with soft lighting",
          "image_url" => "https://example.com/scene1.jpg",
          "status" => "completed"
        }
      }
    })
  end
end
