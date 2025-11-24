defmodule Backend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      BackendWeb.Telemetry,
      Backend.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:backend, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:backend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Backend.PubSub},
      # Pipeline Configuration Agent
      Backend.Pipeline.PipelineConfig,
      # Short-lived audio cache for continuation URLs
      Backend.Services.AudioSegmentStore,
      # Workflow Coordinator GenServer
      Backend.Workflow.Coordinator,
      {Task, fn -> generate_openapi_spec() end},
      # Start to serve requests, typically the last entry
      BackendWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Backend.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BackendWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp generate_openapi_spec do
    Task.start(fn ->
      Process.sleep(2_000)
      write_openapi_spec()
    end)
  end

  defp write_openapi_spec do
    spec_path =
      [:code.priv_dir(:backend), "static", "openapi.json"]
      |> Path.join()

    try do
      BackendWeb.ApiSpec.spec()
      |> Jason.encode!(pretty: true)
      |> then(fn json ->
        File.mkdir_p!(Path.dirname(spec_path))
        File.write!(spec_path, json)
        Logger.info("[OpenAPI] Wrote spec to #{spec_path}")
      end)
    rescue
      exception ->
        Logger.error("[OpenAPI] Failed to generate spec: #{Exception.message(exception)}")
    end
  end
end
