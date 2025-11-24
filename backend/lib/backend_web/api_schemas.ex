defmodule BackendWeb.ApiSchemas do
  @moduledoc """
  JSON schemas used by OpenAPI documentation.
  """
  alias OpenApiSpex.Schema
  require OpenApiSpex

  defmodule Job do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Job",
      description: "A rendered video job.",
      type: :object,
      properties: %{
        job_id: %Schema{type: :integer, description: "Job identifier"},
        type: %Schema{type: :string, enum: ["image_pairs", "property_photos"]},
        status: %Schema{
          type: :string,
          enum: ["pending", "approved", "processing", "completed", "failed"]
        },
        video_name: %Schema{type: :string},
        estimated_cost: %Schema{type: :number, format: :float, nullable: true},
        costs: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            estimated: %Schema{type: :number, format: :float},
            currency: %Schema{type: :string}
          }
        },
        scene_count: %Schema{type: :integer, minimum: 0},
        message: %Schema{type: :string},
        campaign_id: %Schema{type: :string, format: :uuid},
        client_id: %Schema{type: :integer, nullable: true},
        clip_duration: %Schema{type: :number, format: :float},
        num_pairs: %Schema{type: :integer},
        total_assets: %Schema{type: :integer},
        property_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Property scene types requested."
        }
      },
      required: [:job_id, :status, :type, :scene_count]
    })
  end

  defmodule ErrorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Generic error envelope.",
      type: :object,
      properties: %{
        error: %Schema{
          anyOf: [
            %Schema{type: :object, additionalProperties: true},
            %Schema{type: :string}
          ],
          description: "Error message or object describing the failure"
        }
      },
      required: [:error]
    })
  end

  defmodule Client do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Client",
      description: "Represents a brand or customer.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        width: %Schema{type: :integer, nullable: true},
        height: %Schema{type: :integer, nullable: true},
        homepage: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        brand_guidelines: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  defmodule ClientRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClientRequest",
      description: "Payload used to create or update a client.",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        homepage: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        brand_guidelines: %Schema{type: :string, nullable: true}
      },
      required: [:name]
    })
  end

  defmodule ClientResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClientResponse",
      type: :object,
      properties: %{
        data: Client
      },
      required: [:data]
    })
  end

  defmodule ClientListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClientListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Client},
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer}
          }
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule ClientStatsResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClientStatsResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            campaignCount: %Schema{type: :integer},
            videoCount: %Schema{type: :integer},
            totalSpend: %Schema{type: :number}
          }
        }
      },
      required: [:data]
    })
  end

  defmodule Campaign do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Campaign",
      description: "A marketing campaign tied to a client.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        client_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        brief: %Schema{type: :string, nullable: true},
        goal: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, nullable: true},
        product_url: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :client_id, :name]
    })
  end

  defmodule CampaignRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CampaignRequest",
      description: "Payload used to create or update a campaign.",
      type: :object,
      properties: %{
        client_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        brief: %Schema{type: :string, nullable: true},
        goal: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, nullable: true},
        product_url: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name, :client_id]
    })
  end

  defmodule CampaignResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CampaignResponse",
      type: :object,
      properties: %{
        data: Campaign
      },
      required: [:data]
    })
  end

  defmodule CampaignListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CampaignListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Campaign},
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer},
            client_id: %Schema{type: :string, format: :uuid, nullable: true}
          }
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule CampaignStatsResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CampaignStatsResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          additionalProperties: true
        }
      },
      required: [:data]
    })
  end

  defmodule CampaignJobResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CampaignJobResponse",
      description: "Job summary returned when a job is created from a campaign.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :integer},
            type: %Schema{type: :string},
            status: %Schema{type: :string},
            campaign_id: %Schema{type: :string, format: :uuid},
            asset_count: %Schema{type: :integer},
            scene_count: %Schema{type: :integer},
            parameters: %Schema{type: :object, additionalProperties: true}
          },
          required: [:id, :type, :status, :campaign_id]
        },
        links: %Schema{
          type: :object,
          properties: %{
            self: %Schema{type: :string},
            approve: %Schema{type: :string},
            status: %Schema{type: :string}
          }
        }
      },
      required: [:data]
    })
  end

  defmodule CampaignJobRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CampaignJobRequest",
      description: "Optional parameters when creating a job from a campaign.",
      type: :object,
      properties: %{
        scene_count: %Schema{type: :integer, minimum: 1},
        parameters: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule Asset do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Asset",
      description: "Media asset associated with a campaign.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        campaign_id: %Schema{type: :string, format: :uuid, nullable: true},
        client_id: %Schema{type: :string, format: :uuid, nullable: true},
        type: %Schema{type: :string, enum: ["image", "video", "audio"]},
        description: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string, nullable: true},
        width: %Schema{type: :integer, nullable: true},
        height: %Schema{type: :integer, nullable: true},
        tags: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        source_url: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :type]
    })
  end

  defmodule AssetRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetRequest",
      description:
        "Payload used to create an asset via JSON upload. Either campaign_id or client_id must be provided.",
      type: :object,
      properties: %{
        campaign_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Required if client_id is not provided"
        },
        client_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Required if campaign_id is not provided"
        },
        type: %Schema{type: :string, enum: ["image", "video", "audio"]},
        description: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string, nullable: true},
        tags: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        source_url: %Schema{type: :string, description: "URL to download asset from"},
        blob_data: %Schema{
          type: :string,
          format: :byte,
          description: "Base64 encoded binary payload"
        }
      },
      required: [:type]
    })
  end

  defmodule AssetResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetResponse",
      type: :object,
      properties: %{
        data: Asset
      },
      required: [:data]
    })
  end

  defmodule AssetListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Asset},
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer},
            limit: %Schema{type: :integer},
            offset: %Schema{type: :integer}
          }
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AssetBulkRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetBulkRequest",
      description: "Batch request for creating multiple assets from URLs.",
      type: :object,
      properties: %{
        assets: %Schema{
          type: :array,
          items: AssetRequest
        }
      },
      required: [:assets]
    })
  end

  defmodule AssetBulkResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetBulkResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Asset},
        meta: %Schema{
          type: :object,
          properties: %{
            created: %Schema{type: :integer},
            failed: %Schema{type: :integer},
            errors: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                additionalProperties: true
              }
            }
          }
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule JobCreationRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobCreationRequest",
      description: "Parameters accepted when spawning a new job.",
      type: :object,
      properties: %{
        campaign_id: %Schema{type: :string, format: :uuid},
        property_types: %Schema{
          nullable: true,
          type: :array,
          items: %Schema{type: :string}
        },
        parameters: %Schema{type: :object, additionalProperties: true}
      },
      required: [:campaign_id],
      example: %{
        "campaign_id" => "5e1cb386-7e62-4a4f-92b3-938117b2a3d3",
        "parameters" => %{"style" => "modern"}
      }
    })
  end

  defmodule JobCreationResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobCreationResponse",
      description: "Response returned when a job is created.",
      type: :object,
      properties:
        Map.merge(Job.schema().properties, %{
          scene_count: %Schema{type: :integer},
          message: %Schema{type: :string},
          storyboard_ready: %Schema{type: :boolean},
          storyboard: %Schema{
            type: :object,
            properties: %{
              scenes: %Schema{
                type: :array,
                items: %Schema{type: :object, additionalProperties: true}
              },
              total_duration: %Schema{type: :number, nullable: true}
            }
          }
        }),
      required: [:job_id, :status, :type, :scene_count]
    })
  end

  defmodule JobApprovalResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobApprovalResponse",
      description: "Response returned after approving a job.",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        job_id: %Schema{type: :integer},
        status: %Schema{type: :string}
      },
      required: [:message, :job_id, :status],
      example: %{
        "message" => "Job approved successfully",
        "status" => "approved",
        "job_id" => 123
      }
    })
  end

  defmodule JobShowResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobShowResponse",
      description: "Response body returned when fetching a job.",
      type: :object,
      properties: %{
        job_id: %Schema{type: :integer},
        type: %Schema{type: :string},
        status: %Schema{type: :string},
        video_name: %Schema{type: :string},
        estimated_cost: %Schema{type: :number, format: :float, nullable: true},
        costs: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            estimated: %Schema{type: :number, format: :float},
            currency: %Schema{type: :string}
          }
        },
        progress_percentage: %Schema{type: :number},
        current_stage: %Schema{type: :string},
        parameters: %Schema{type: :object, additionalProperties: true},
        storyboard: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:job_id, :status, :type]
    })
  end
end
