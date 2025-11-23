defmodule BackendWeb.Schemas.ClientSchemas do
  @moduledoc """
  OpenAPI schemas for Client-related requests and responses
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule Client do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Client",
      description: "A client entity",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Client ID"},
        name: %Schema{type: :string, description: "Client name", minLength: 1, maxLength: 255},
        description: %Schema{type: :string, description: "Client description", nullable: true},
        homepage: %Schema{type: :string, description: "Client homepage URL", nullable: true},
        metadata: %Schema{type: :object, description: "Additional metadata", nullable: true},
        brand_guidelines: %Schema{
          type: :string,
          description: "Brand guidelines for the client",
          nullable: true
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
      required: [:id, :name],
      example: %{
        "id" => "123e4567-e89b-12d3-a456-426614174000",
        "name" => "Acme Corp",
        "description" => "Leading provider of innovative solutions",
        "homepage" => "https://acme.com",
        "metadata" => %{"industry" => "technology"},
        "brand_guidelines" => "Use blue and white colors",
        "inserted_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z"
      }
    })
  end

  defmodule ClientRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ClientRequest",
      description: "Request body for creating or updating a client",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Client name", minLength: 1, maxLength: 255},
        description: %Schema{type: :string, description: "Client description"},
        homepage: %Schema{type: :string, description: "Client homepage URL"},
        metadata: %Schema{type: :object, description: "Additional metadata"},
        brand_guidelines: %Schema{type: :string, description: "Brand guidelines for the client"}
      },
      required: [:name],
      example: %{
        "name" => "Acme Corp",
        "description" => "Leading provider of innovative solutions",
        "homepage" => "https://acme.com",
        "metadata" => %{"industry" => "technology"},
        "brand_guidelines" => "Use blue and white colors"
      }
    })
  end

  defmodule ClientResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ClientResponse",
      description: "Response containing a single client",
      type: :object,
      properties: %{
        data: Client
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => "123e4567-e89b-12d3-a456-426614174000",
          "name" => "Acme Corp",
          "description" => "Leading provider of innovative solutions",
          "homepage" => "https://acme.com",
          "metadata" => %{"industry" => "technology"},
          "brand_guidelines" => "Use blue and white colors",
          "inserted_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-01T00:00:00Z"
        }
      }
    })
  end

  defmodule ClientsResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ClientsResponse",
      description: "Response containing a list of clients",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Client}
      },
      required: [:data],
      example: %{
        "data" => [
          %{
            "id" => "123e4567-e89b-12d3-a456-426614174000",
            "name" => "Acme Corp",
            "description" => "Leading provider of innovative solutions",
            "homepage" => "https://acme.com",
            "metadata" => %{"industry" => "technology"},
            "brand_guidelines" => "Use blue and white colors",
            "inserted_at" => "2024-01-01T00:00:00Z",
            "updated_at" => "2024-01-01T00:00:00Z"
          }
        ]
      }
    })
  end

  defmodule ClientStats do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ClientStats",
      description: "Statistics for a client",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            campaigns_count: %Schema{type: :integer, description: "Total number of campaigns"},
            assets_count: %Schema{type: :integer, description: "Total number of assets"}
          }
        }
      },
      example: %{
        "data" => %{
          "campaigns_count" => 5,
          "assets_count" => 20
        }
      }
    })
  end
end
