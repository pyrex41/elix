defmodule BackendWeb.OpenApiController do
  @moduledoc """
  Controller for serving API documentation.
  """
  use BackendWeb, :controller

  @doc """
  Returns a simple JSON list of all API routes.
  """
  def spec(conn, _params) do
    routes = [
      %{
        path: "/api/v3/clients",
        methods: ["GET", "POST"],
        description: "Client management"
      },
      %{
        path: "/api/v3/clients/:id",
        methods: ["GET", "PUT", "DELETE"],
        description: "Individual client operations"
      },
      %{
        path: "/api/v3/clients/:id/campaigns",
        methods: ["GET"],
        description: "Get campaigns for a client"
      },
      %{
        path: "/api/v3/campaigns",
        methods: ["GET", "POST"],
        description: "Campaign management"
      },
      %{
        path: "/api/v3/campaigns/:id",
        methods: ["GET", "PUT", "DELETE"],
        description: "Individual campaign operations"
      },
      %{
        path: "/api/v3/campaigns/:id/assets",
        methods: ["GET"],
        description: "Get assets for a campaign"
      },
      %{
        path: "/api/v3/campaigns/:id/create-job",
        methods: ["POST"],
        description: "Create a job from a campaign"
      },
      %{
        path: "/api/v3/assets/unified",
        methods: ["POST"],
        description: "Upload an asset via file or URL"
      },
      %{
        path: "/api/v3/assets/:id/data",
        methods: ["GET"],
        description: "Get asset data"
      },
      %{
        path: "/api/v3/jobs/from-image-pairs",
        methods: ["POST"],
        description: "Create job from image pairs"
      },
      %{
        path: "/api/v3/jobs/from-property-photos",
        methods: ["POST"],
        description: "Create job from property photos"
      },
      %{
        path: "/api/v3/jobs/:id/approve",
        methods: ["POST"],
        description: "Approve a job"
      },
      %{
        path: "/api/v3/jobs/:id",
        methods: ["GET"],
        description: "Get job details"
      },
      %{
        path: "/api/v3/jobs/:job_id/scenes",
        methods: ["GET"],
        description: "List scenes for a job"
      },
      %{
        path: "/api/v3/jobs/:job_id/scenes/:scene_id",
        methods: ["GET", "PUT", "DELETE"],
        description: "Individual scene operations"
      },
      %{
        path: "/api/v3/jobs/:job_id/scenes/:scene_id/regenerate",
        methods: ["POST"],
        description: "Regenerate a scene"
      },
      %{
        path: "/api/v3/videos/:job_id/combined",
        methods: ["GET"],
        description: "Get combined video"
      },
      %{
        path: "/api/v3/videos/:job_id/thumbnail",
        methods: ["GET"],
        description: "Get video thumbnail"
      },
      %{
        path: "/api/v3/videos/:job_id/clips/:filename",
        methods: ["GET"],
        description: "Get video clip"
      },
      %{
        path: "/api/v3/videos/:job_id/clips/:filename/thumbnail",
        methods: ["GET"],
        description: "Get clip thumbnail"
      },
      %{
        path: "/api/v3/audio/generate-scenes",
        methods: ["POST"],
        description: "Generate audio for scenes"
      },
      %{
        path: "/api/v3/audio/status/:job_id",
        methods: ["GET"],
        description: "Get audio generation status"
      },
      %{
        path: "/api/v3/audio/:job_id/download",
        methods: ["GET"],
        description: "Download generated audio"
      }
    ]

    json(conn, %{
      api: "Video Generation API",
      version: "3.0.0",
      routes: routes
    })
  end
end
