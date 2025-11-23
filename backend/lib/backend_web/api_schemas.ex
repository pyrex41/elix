defmodule BackendWeb.ApiSchemas do
  @moduledoc """
  JSON schemas used by OpenAPI documentation.
  """
  alias OpenApiSpex.Schema
  require OpenApiSpex

  defmodule Job do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Job",
      description: "A rendered video job.",
      type: :object,
      properties: %{
        job_id: %Schema{type: :integer, description: "Job identifier"},
        type: %Schema{type: :string, enum: ["image_pairs", "property_photos"]},
        status: %Schema{
          type: :string,
          enum: ["pending", "approved", "processing", "completed", "failed"]
        },
        scene_count: %Schema{type: :integer, minimum: 0},
        message: %Schema{type: :string},
        campaign_id: %Schema{type: :string, format: :uuid},
        client_id: %Schema{type: :integer, nullable: true},
        clip_duration: %Schema{type: :number, format: :float},
        num_pairs: %Schema{type: :integer},
        total_assets: %Schema{type: :integer},
        property_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Property scene types requested."
        }
      },
      required: [:job_id, :status, :type, :scene_count]
    })
  end

  defmodule JobCreationRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobCreationRequest",
      description: "Parameters accepted when spawning a new job.",
      type: :object,
      properties: %{
        campaign_id: %Schema{type: :string, format: :uuid},
        property_types: %Schema{
          nullable: true,
          type: :array,
          items: %Schema{type: :string}
        },
        parameters: %Schema{type: :object, additionalProperties: true}
      },
      required: [:campaign_id],
      example: %{
        "campaign_id" => "5e1cb386-7e62-4a4f-92b3-938117b2a3d3",
        "parameters" => %{"style" => "modern"}
      }
    })
  end

  defmodule JobCreationResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobCreationResponse",
      description: "Response returned when a job is created.",
      type: :object,
      properties:
        Map.merge(Job.schema().properties, %{
          scene_count: %Schema{type: :integer},
          message: %Schema{type: :string}
        }),
      required: [:job_id, :status, :type, :scene_count]
    })
  end

  defmodule JobApprovalResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobApprovalResponse",
      description: "Response returned after approving a job.",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        job_id: %Schema{type: :integer},
        status: %Schema{type: :string}
      },
      required: [:message, :job_id, :status],
      example: %{
        "message" => "Job approved successfully",
        "status" => "approved",
        "job_id" => 123
      }
    })
  end

  defmodule JobShowResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JobShowResponse",
      description: "Response body returned when fetching a job.",
      type: :object,
      properties: %{
        job_id: %Schema{type: :integer},
        type: %Schema{type: :string},
        status: %Schema{type: :string},
        progress_percentage: %Schema{type: :number},
        current_stage: %Schema{type: :string},
        parameters: %Schema{type: :object, additionalProperties: true},
        storyboard: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:job_id, :status, :type]
    })
  end
end
