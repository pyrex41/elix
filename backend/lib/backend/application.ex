defmodule Backend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize ETS table for temporary audio storage (for Replicate continuation)
    :ets.new(:temp_audio_store, [:named_table, :public, :set])
    
    children = [
      BackendWeb.Telemetry,
      Backend.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:backend, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:backend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Backend.PubSub},
      # Pipeline Configuration Agent
      Backend.Pipeline.PipelineConfig,
      # Workflow Coordinator GenServer
      Backend.Workflow.Coordinator,
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
end
