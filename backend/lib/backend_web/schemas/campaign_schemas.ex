defmodule BackendWeb.Schemas.CampaignSchemas do
  @moduledoc """
  OpenAPI schemas for Campaign-related requests and responses
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule Campaign do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Campaign",
      description: "A campaign entity",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Campaign ID"},
        name: %Schema{type: :string, description: "Campaign name", minLength: 1, maxLength: 255},
        brief: %Schema{type: :string, description: "Campaign brief", nullable: true},
        goal: %Schema{type: :string, description: "Campaign goal", nullable: true},
        status: %Schema{type: :string, description: "Campaign status", nullable: true},
        product_url: %Schema{type: :string, description: "Product URL", nullable: true},
        metadata: %Schema{type: :object, description: "Additional metadata", nullable: true},
        client_id: %Schema{type: :string, format: :uuid, description: "Associated client ID"},
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
      required: [:id, :name, :client_id],
      example: %{
        "id" => "223e4567-e89b-12d3-a456-426614174000",
        "name" => "Spring Campaign 2024",
        "brief" => "Launch new product line for spring season",
        "goal" => "Increase brand awareness by 30%",
        "status" => "active",
        "product_url" => "https://acme.com/products/spring-2024",
        "metadata" => %{"budget" => 50000},
        "client_id" => "123e4567-e89b-12d3-a456-426614174000",
        "inserted_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z"
      }
    })
  end

  defmodule CampaignRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "CampaignRequest",
      description: "Request body for creating or updating a campaign",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Campaign name", minLength: 1, maxLength: 255},
        brief: %Schema{type: :string, description: "Campaign brief"},
        goal: %Schema{type: :string, description: "Campaign goal"},
        status: %Schema{type: :string, description: "Campaign status"},
        product_url: %Schema{type: :string, description: "Product URL"},
        metadata: %Schema{type: :object, description: "Additional metadata"},
        client_id: %Schema{type: :string, format: :uuid, description: "Associated client ID"}
      },
      required: [:name, :client_id],
      example: %{
        "name" => "Spring Campaign 2024",
        "brief" => "Launch new product line for spring season",
        "goal" => "Increase brand awareness by 30%",
        "status" => "active",
        "product_url" => "https://acme.com/products/spring-2024",
        "metadata" => %{"budget" => 50000},
        "client_id" => "123e4567-e89b-12d3-a456-426614174000"
      }
    })
  end

  defmodule CampaignResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "CampaignResponse",
      description: "Response containing a single campaign",
      type: :object,
      properties: %{
        data: Campaign
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => "223e4567-e89b-12d3-a456-426614174000",
          "name" => "Spring Campaign 2024",
          "brief" => "Launch new product line for spring season",
          "goal" => "Increase brand awareness by 30%",
          "status" => "active",
          "product_url" => "https://acme.com/products/spring-2024",
          "metadata" => %{"budget" => 50000},
          "client_id" => "123e4567-e89b-12d3-a456-426614174000",
          "inserted_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule CampaignsResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "CampaignsResponse",
      description: "Response containing a list of campaigns",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Campaign}
      },
      required: [:data],
      example: %{
        "data" => [
          %{
            "id" => "223e4567-e89b-12d3-a456-426614174000",
            "name" => "Spring Campaign 2024",
            "brief" => "Launch new product line for spring season",
            "goal" => "Increase brand awareness by 30%",
            "status" => "active",
            "product_url" => "https://acme.com/products/spring-2024",
            "metadata" => %{"budget" => 50000},
            "client_id" => "123e4567-e89b-12d3-a456-426614174000",
            "inserted_at" => "2024-01-01T00:00:00Z",
            "updated_at" => "2024-01-01T00:00:00Z"
          }
        ]
      }
    })
  end

  defmodule CampaignStats do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "CampaignStats",
      description: "Statistics for a campaign",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            assets_count: %Schema{type: :integer, description: "Total number of assets"}
          }
        }
      },
      example: %{
        "data" => %{
          "assets_count" => 10
        }
      }
    })
  end
end
