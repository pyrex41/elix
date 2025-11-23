defmodule BackendWeb.ApiSpec do
  @moduledoc """
  Generates the OpenAPI specification for the Backend API.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
  @behaviour OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Backend API",
        version: application_version(),
        description: "Programmatic interface for the AI video generation platform."
      },
      servers: [
        Server.from_endpoint(BackendWeb.Endpoint)
      ],
      paths: Paths.from_router(BackendWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp application_version do
    :backend
    |> Application.spec(:vsn)
    |> to_string()
  rescue
    _ -> "0.0.0"
  end
end
