defmodule BackendWeb.OpenApiController do
  @moduledoc """
  Controller for serving the OpenAPI specification.
  """
  use BackendWeb, :controller

  alias BackendWeb.ApiSpec

  @doc """
  Renders the OpenAPI specification as JSON.
  """
  def spec(conn, _params) do
    spec = ApiSpec.spec()
    json(conn, spec)
  end
end