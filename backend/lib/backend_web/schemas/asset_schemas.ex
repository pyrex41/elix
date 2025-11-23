defmodule BackendWeb.Schemas.AssetSchemas do
  @moduledoc """
  OpenAPI schemas for Asset-related requests and responses
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule Asset do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Asset",
      description: "An asset entity (image, video, or audio)",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Asset ID"},
        type: %Schema{
          type: :string,
          enum: ["image", "video", "audio"],
          description: "Asset type"
        },
        metadata: %Schema{type: :object, description: "Additional metadata", nullable: true},
        source_url: %Schema{type: :string, description: "Source URL", nullable: true},
        campaign_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Associated campaign ID"
        },
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
      required: [:id, :type, :campaign_id],
      example: %{
        "id" => "323e4567-e89b-12d3-a456-426614174000",
        "type" => "image",
        "metadata" => %{"width" => 1920, "height" => 1080},
        "source_url" => "https://example.com/image.jpg",
        "campaign_id" => "223e4567-e89b-12d3-a456-426614174000",
        "inserted_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z"
      }
    })
  end

  defmodule AssetRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AssetRequest",
      description: "Request body for creating an asset",
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          enum: ["image", "video", "audio"],
          description: "Asset type"
        },
        metadata: %Schema{type: :object, description: "Additional metadata"},
        source_url: %Schema{type: :string, description: "Source URL"},
        campaign_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Associated campaign ID"
        },
        blob_data: %Schema{
          type: :string,
          format: :binary,
          description: "Binary data of the asset (base64 encoded)"
        }
      },
      required: [:type, :campaign_id],
      example: %{
        "type" => "image",
        "metadata" => %{"width" => 1920, "height" => 1080},
        "source_url" => "https://example.com/image.jpg",
        "campaign_id" => "223e4567-e89b-12d3-a456-426614174000"
      }
    })
  end

  defmodule AssetFromUrlRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AssetFromUrlRequest",
      description: "Request body for creating an asset from URL",
      type: :object,
      properties: %{
        source_url: %Schema{type: :string, description: "Source URL"},
        campaign_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Associated campaign ID"
        }
      },
      required: [:source_url, :campaign_id],
      example: %{
        "source_url" => "https://example.com/image.jpg",
        "campaign_id" => "223e4567-e89b-12d3-a456-426614174000"
      }
    })
  end

  defmodule AssetFromUrlsRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AssetFromUrlsRequest",
      description: "Request body for creating multiple assets from URLs",
      type: :object,
      properties: %{
        source_urls: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "List of source URLs"
        },
        campaign_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Associated campaign ID"
        }
      },
      required: [:source_urls, :campaign_id],
      example: %{
        "source_urls" => [
          "https://example.com/image1.jpg",
          "https://example.com/image2.jpg"
        ],
        "campaign_id" => "223e4567-e89b-12d3-a456-426614174000"
      }
    })
  end

  defmodule AssetResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AssetResponse",
      description: "Response containing a single asset",
      type: :object,
      properties: %{
        data: Asset
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => "323e4567-e89b-12d3-a456-426614174000",
          "type" => "image",
          "metadata" => %{"width" => 1920, "height" => 1080},
          "source_url" => "https://example.com/image.jpg",
          "campaign_id" => "223e4567-e89b-12d3-a456-426614174000",
          "inserted_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule AssetsResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "AssetsResponse",
      description: "Response containing a list of assets with pagination metadata",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Asset},
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer, description: "Total number of assets"},
            limit: %Schema{type: :integer, description: "Number of assets per page"},
            offset: %Schema{type: :integer, description: "Offset for pagination"}
          }
        }
      },
      required: [:data],
      example: %{
        "data" => [
          %{
            "id" => "323e4567-e89b-12d3-a456-426614174000",
            "type" => "image",
            "metadata" => %{"width" => 1920, "height" => 1080},
            "source_url" => "https://example.com/image.jpg",
            "campaign_id" => "223e4567-e89b-12d3-a456-426614174000",
            "inserted_at" => "2024-01-01T00:00:00Z",
            "updated_at" => "2024-01-01T00:00:00Z"
          }
        ],
        "meta" => %{
          "total" => 100,
          "limit" => 20,
          "offset" => 0
        }
      }
    })
  end
end
