defmodule BackendWeb.ApiSpec do
  @moduledoc """
  OpenAPI Specification for the Backend API
  """
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias BackendWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [
        Server.from_endpoint(Endpoint)
      ],
      info: %Info{
        title: "Backend API",
        version: "3.0",
        description: """
        Backend API for managing clients, campaigns, assets, jobs, and media generation.

        ## Authentication

        Most endpoints require API key authentication via the `X-API-Key` header.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "api_key" => %SecurityScheme{
            type: "apiKey",
            name: "X-API-Key",
            in: "header",
            description: "API key for authentication"
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
