defmodule Mix.Tasks.Backend.Openapispec do
  @moduledoc """
  Generates the OpenAPI specification as JSON.
  """
  use Mix.Task

  @shortdoc "Write the OpenAPI spec to disk"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    output_path =
      case args do
        [path | _] -> path
        _ -> Path.join(["priv", "static", "openapi.json"])
      end

    spec =
      BackendWeb.ApiSpec.spec()
      |> Jason.encode!(pretty: true)

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, spec)

    Mix.shell().info("Wrote OpenAPI spec to #{output_path}")
  end
end
