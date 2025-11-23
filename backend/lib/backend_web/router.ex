defmodule BackendWeb.Router do
  use BackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: BackendWeb.ApiSpec
  end

  pipeline :api_authenticated do
    plug BackendWeb.Plugs.ApiKeyAuth
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug OpenApiSpex.Plug.PutApiSpec, module: BackendWeb.ApiSpec
  end

  scope "/api", BackendWeb do
    pipe_through :api

    # OpenAPI spec endpoint (JSON)
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/", BackendWeb do
    pipe_through :browser

    # SwaggerUI endpoint
    get "/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  scope "/api", BackendWeb do
    pipe_through [:api, :api_authenticated]

    # API v3 routes
    scope "/v3", Api.V3 do
      # Client management endpoints
      resources "/clients", ClientController, except: [:new, :edit]
      get "/clients/:id/campaigns", ClientController, :get_campaigns
      get "/clients/:id/stats", ClientController, :stats

      # Campaign management endpoints
      resources "/campaigns", CampaignController, except: [:new, :edit]
      get "/campaigns/:id/assets", CampaignController, :get_assets
      get "/campaigns/:id/stats", CampaignController, :stats
      post "/campaigns/:id/create-job", CampaignController, :create_job

      # Asset management endpoints
      resources "/assets", AssetController, only: [:index, :show, :create, :delete]
      post "/assets/from-url", AssetController, :from_url
      post "/assets/from-urls", AssetController, :from_urls
      post "/assets/unified", AssetController, :unified

      # Job creation endpoints
      post "/jobs/from-image-pairs", JobCreationController, :from_image_pairs
      post "/jobs/from-property-photos", JobCreationController, :from_property_photos

      # Job management endpoints
      post "/jobs/:id/approve", JobController, :approve
      get "/jobs/:id", JobController, :show

      # Scene management endpoints
      get "/jobs/:job_id/scenes", SceneController, :index
      get "/jobs/:job_id/scenes/:scene_id", SceneController, :show
      put "/jobs/:job_id/scenes/:scene_id", SceneController, :update
      post "/jobs/:job_id/scenes/:scene_id/regenerate", SceneController, :regenerate
      delete "/jobs/:job_id/scenes/:scene_id", SceneController, :delete

      # Video serving endpoints
      get "/videos/:job_id/combined", VideoController, :combined
      get "/videos/:job_id/thumbnail", VideoController, :thumbnail
      get "/videos/:job_id/clips/:filename", VideoController, :clip
      get "/videos/:job_id/clips/:filename/thumbnail", VideoController, :clip_thumbnail

      # Audio generation endpoints
      post "/audio/generate-scenes", AudioController, :generate_scenes
      get "/audio/status/:job_id", AudioController, :status
      get "/audio/:job_id/download", AudioController, :download
    end
  end

  scope "/api", BackendWeb do
    pipe_through :api

    scope "/v3", Api.V3 do
      get "/assets/:id/data", AssetController, :data
      get "/assets/:id/thumbnail", AssetController, :thumbnail
    end

    post "/webhooks/replicate", Api.V3.WebhookController, :replicate
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:backend, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: BackendWeb.Telemetry
    end
  end
end
