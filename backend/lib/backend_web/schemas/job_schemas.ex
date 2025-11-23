defmodule BackendWeb.Schemas.JobSchemas do
  @moduledoc """
  OpenAPI schemas for Job-related operations.
  """

  alias OpenApiSpex.Schema

  defmodule Job do
    @moduledoc """
    Schema for a Job resource.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Job",
      description: "A video generation job",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Job ID"},
        type: %Schema{
          type: :string,
          enum: [:image_pairs, :property_photos],
          description: "Job type"
        },
        status: %Schema{
          type: :string,
          enum: [:pending, :approved, :processing, :completed, :failed],
          description: "Job status"
        },
        parameters: %Schema{
          type: :object,
          description: "Job parameters",
          additionalProperties: true
        },
        storyboard: %Schema{
          type: :object,
          description: "Generated storyboard",
          additionalProperties: true
        },
        progress: %Schema{
          type: :object,
          properties: %{
            percentage: %Schema{type: :integer, minimum: 0, maximum: 100},
            stage: %Schema{type: :string},
            message: %Schema{type: :string}
          }
        },
        result: %Schema{
          type: :object,
          description: "Job result",
          properties: %{
            video_url: %Schema{type: :string, format: :uri},
            thumbnail_url: %Schema{type: :string, format: :uri},
            duration_seconds: %Schema{type: :number}
          }
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
      required: [:id, :type, :status],
      example: %{
        "id" => 123,
        "type" => "image_pairs",
        "status" => "processing",
        "parameters" => %{
          "style" => "modern",
          "music_genre" => "upbeat"
        },
        "progress" => %{
          "percentage" => 45,
          "stage" => "rendering",
          "message" => "Rendering scene 3 of 6"
        },
        "inserted_at" => "2025-11-23T12:34:55Z",
        "updated_at" => "2025-11-23T12:35:30Z"
      }
    })
  end

  defmodule ImagePairsJobRequest do
    @moduledoc """
    Schema for image pairs job creation request.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImagePairsJobRequest",
      description: "Request to create a job from image pairs",
      type: :object,
      properties: %{
        image_pairs: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              before_asset_id: %Schema{type: :integer, description: "Asset ID for 'before' image"},
              after_asset_id: %Schema{type: :integer, description: "Asset ID for 'after' image"},
              caption: %Schema{type: :string, description: "Optional caption for the pair"}
            },
            required: [:before_asset_id, :after_asset_id]
          },
          minItems: 1
        },
        style: %Schema{
          type: :string,
          description: "Video style",
          enum: [:modern, :classic, :minimalist, :dramatic],
          default: :modern
        },
        music_genre: %Schema{
          type: :string,
          description: "Music genre for the video",
          enum: [:upbeat, :calm, :corporate, :energetic],
          default: :upbeat
        },
        duration_seconds: %Schema{
          type: :integer,
          description: "Target video duration in seconds",
          minimum: 10,
          maximum: 120,
          default: 30
        }
      },
      required: [:image_pairs],
      example: %{
        "image_pairs" => [
          %{
            "before_asset_id" => 1,
            "after_asset_id" => 2,
            "caption" => "Kitchen renovation"
          },
          %{
            "before_asset_id" => 3,
            "after_asset_id" => 4,
            "caption" => "Living room transformation"
          }
        ],
        "style" => "modern",
        "music_genre" => "upbeat",
        "duration_seconds" => 30
      }
    })
  end

  defmodule PropertyPhotosJobRequest do
    @moduledoc """
    Schema for property photos job creation request.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PropertyPhotosJobRequest",
      description: "Request to create a job from property photos",
      type: :object,
      properties: %{
        asset_ids: %Schema{
          type: :array,
          items: %Schema{type: :integer},
          description: "List of asset IDs for property photos",
          minItems: 1
        },
        property_details: %Schema{
          type: :object,
          properties: %{
            address: %Schema{type: :string},
            price: %Schema{type: :number},
            bedrooms: %Schema{type: :integer},
            bathrooms: %Schema{type: :number},
            square_feet: %Schema{type: :integer},
            description: %Schema{type: :string}
          }
        },
        style: %Schema{
          type: :string,
          description: "Video style",
          enum: [:luxury, :modern, :cozy, :professional],
          default: :professional
        },
        music_genre: %Schema{
          type: :string,
          description: "Music genre for the video",
          enum: [:ambient, :upbeat, :classical, :electronic],
          default: :ambient
        }
      },
      required: [:asset_ids],
      example: %{
        "asset_ids" => [5, 6, 7, 8, 9],
        "property_details" => %{
          "address" => "123 Main St, San Francisco, CA",
          "price" => 1250000,
          "bedrooms" => 3,
          "bathrooms" => 2.5,
          "square_feet" => 2400,
          "description" => "Beautiful modern home with ocean views"
        },
        "style" => "luxury",
        "music_genre" => "ambient"
      }
    })
  end

  defmodule JobResponse do
    @moduledoc """
    Schema for job response.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobResponse",
      description: "Response containing a job",
      type: :object,
      properties: %{
        data: Job,
        links: %Schema{
          type: :object,
          properties: %{
            self: %Schema{type: :string, format: :uri},
            approve: %Schema{type: :string, format: :uri},
            status: %Schema{type: :string, format: :uri},
            video: %Schema{type: :string, format: :uri}
          }
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => 123,
          "type" => "image_pairs",
          "status" => "pending",
          "parameters" => %{
            "style" => "modern",
            "music_genre" => "upbeat"
          },
          "inserted_at" => "2025-11-23T12:34:55Z",
          "updated_at" => "2025-11-23T12:34:55Z"
        },
        "links" => %{
          "self" => "/api/v3/jobs/123",
          "approve" => "/api/v3/jobs/123/approve",
          "status" => "/api/v3/jobs/123",
          "video" => "/api/v3/videos/123"
        }
      }
    })
  end

  defmodule JobApprovalResponse do
    @moduledoc """
    Schema for job approval response.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobApprovalResponse",
      description: "Response after approving a job",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        job_id: %Schema{type: :integer},
        status: %Schema{type: :string}
      },
      required: [:message, :job_id, :status],
      example: %{
        "message" => "Job approved successfully",
        "job_id" => 123,
        "status" => "approved"
      }
    })
  end
end