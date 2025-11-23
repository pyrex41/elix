defmodule BackendWeb.ApiSpec do
  @moduledoc """
  Main OpenAPI specification for the Backend API.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server, Tag}
  alias BackendWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Video Generation API",
        version: "3.0.0",
        description: """
        API for video generation using AI models.

        This API provides endpoints for:
        - Asset management (upload and retrieval)
        - Job creation (image pairs and property photos)
        - Job management (status polling and approval)
        - Scene management
        - Video serving with CDN optimization
        """
      },
      servers: [
        # Populate the Server info from a phoenix endpoint
        Server.from_endpoint(Endpoint)
      ],
      tags: [
        %Tag{
          name: "Assets",
          description: "Asset management endpoints"
        },
        %Tag{
          name: "Jobs",
          description: "Job creation and management"
        },
        %Tag{
          name: "Scenes",
          description: "Scene management for jobs"
        },
        %Tag{
          name: "Videos",
          description: "Video streaming and serving"
        }
      ],
      components: %Components{
        securitySchemes: %{
          "api_key" => %SecurityScheme{
            type: "apiKey",
            in: "header",
            name: "X-API-Key",
            description: "API key for authentication"
          }
        }
      },
      # Optional global security (can be overridden per operation)
      security: [],
      # Populate the paths from a phoenix router
      paths: Paths.from_router(Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end