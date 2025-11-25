defmodule BackendWeb.Router do
  use BackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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
  end

  scope "/api" do
    pipe_through :api

    # OpenAPI spec endpoints (legacy /openapi kept for backwards compatibility)
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/" do
    pipe_through :browser

    # Swagger UI served from CDN
    get "/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
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
      get "/generated-videos", JobController, :generated_videos
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

      # Testing endpoints (can be disabled via config)
      if Application.compile_env(:backend, :enable_testing_endpoints, true) do
        scope "/testing" do
          # Scene template endpoints
          get "/scene-templates", TestingController, :scene_templates
          post "/scene-templates/adapt", TestingController, :adapt_scene_templates

          # Image selection testing
          post "/image-selection", TestingController, :test_image_selection

          # Music generation testing
          post "/music/single-scene", TestingController, :test_single_scene_music
          post "/music/multi-scene", TestingController, :test_multi_scene_music
          post "/music/from-templates", TestingController, :test_music_from_templates

          # Text overlay testing
          post "/overlay/text", TestingController, :test_text_overlay
          post "/overlay/preview", TestingController, :preview_text_overlay

          # Voiceover testing
          post "/voiceover/generate", TestingController, :test_voiceover_generation
          post "/voiceover/script", TestingController, :generate_voiceover_script

          # Avatar overlay testing (stub for future)
          post "/avatar/preview", TestingController, :test_avatar_overlay

          # Pipeline control endpoints
          get "/pipeline/config", TestingController, :get_pipeline_config
          post "/pipeline/config", TestingController, :update_pipeline_config

          # Prompt preview endpoints
          post "/prompt-preview", TestingController, :prompt_preview

          # Resource listing endpoints
          get "/campaigns", TestingController, :list_campaigns
          get "/campaigns/:id/assets", TestingController, :campaign_assets
          get "/jobs/:id/preview", TestingController, :job_preview

          # Testing UI
          get "/ui", TestingController, :testing_ui
        end
      end
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
