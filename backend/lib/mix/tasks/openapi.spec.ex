defmodule Mix.Tasks.Openapi.Spec do
  @moduledoc """
  Mix task to generate the OpenAPI specification file.

  ## Usage

      mix openapi.spec [output_file]

  If no output file is specified, defaults to `openapi.json`.

  ## Examples

      mix openapi.spec
      mix openapi.spec priv/static/openapi.json
      mix openapi.spec docs/api-spec.json
  """
  use Mix.Task

  @shortdoc "Generates the OpenAPI specification file"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    output_file =
      case args do
        [file] -> file
        [] -> "openapi.json"
        _ -> Mix.raise("Usage: mix openapi.spec [output_file]")
      end

    spec =
      BackendWeb.ApiSpec.spec()
      |> Jason.encode!(pretty: true)

    File.write!(output_file, spec)

    Mix.shell().info("OpenAPI spec written to #{output_file}")
  end
end
