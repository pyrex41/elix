defmodule BackendWeb.Schemas.AssetSchemas do
  @moduledoc """
  OpenAPI schemas for Asset-related operations.
  """

  alias OpenApiSpex.Schema

  defmodule Asset do
    @moduledoc """
    Schema for an Asset resource.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Asset",
      description: "An uploaded asset (image, video, etc)",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Asset ID"},
        filename: %Schema{type: :string, description: "Original filename"},
        mime_type: %Schema{type: :string, description: "MIME type of the asset"},
        size: %Schema{type: :integer, description: "File size in bytes"},
        metadata: %Schema{
          type: :object,
          description: "Additional metadata",
          additionalProperties: true
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
      required: [:id, :filename, :mime_type, :size],
      example: %{
        "id" => 123,
        "filename" => "property-photo.jpg",
        "mime_type" => "image/jpeg",
        "size" => 245678,
        "metadata" => %{
          "width" => 1920,
          "height" => 1080
        },
        "inserted_at" => "2025-11-23T12:34:55Z",
        "updated_at" => "2025-11-23T12:34:55Z"
      }
    })
  end

  defmodule AssetUploadRequest do
    @moduledoc """
    Schema for asset upload request.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetUploadRequest",
      description: "Request body for uploading an asset",
      type: :object,
      oneOf: [
        %Schema{
          type: :object,
          properties: %{
            file: %Schema{
              type: :string,
              format: :binary,
              description: "File data"
            }
          },
          required: [:file]
        },
        %Schema{
          type: :object,
          properties: %{
            url: %Schema{
              type: :string,
              format: :uri,
              description: "URL to fetch the asset from"
            }
          },
          required: [:url]
        }
      ]
    })
  end

  defmodule AssetResponse do
    @moduledoc """
    Schema for asset response.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AssetResponse",
      description: "Response containing an asset",
      type: :object,
      properties: %{
        data: Asset,
        metadata: %Schema{
          type: :object,
          properties: %{
            upload_duration_ms: %Schema{type: :integer, description: "Upload duration in milliseconds"},
            processing_status: %Schema{type: :string, enum: [:completed, :pending, :failed]}
          }
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => 123,
          "filename" => "property-photo.jpg",
          "mime_type" => "image/jpeg",
          "size" => 245678,
          "metadata" => %{
            "width" => 1920,
            "height" => 1080
          },
          "inserted_at" => "2025-11-23T12:34:55Z",
          "updated_at" => "2025-11-23T12:34:55Z"
        },
        "metadata" => %{
          "upload_duration_ms" => 234,
          "processing_status" => "completed"
        }
      }
    })
  end
end