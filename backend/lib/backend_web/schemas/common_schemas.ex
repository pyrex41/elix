defmodule BackendWeb.Schemas.CommonSchemas do
  @moduledoc """
  Common OpenAPI schemas for error responses and shared structures
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule ErrorResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Error response",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            message: %Schema{type: :string, description: "Error message"},
            code: %Schema{type: :string, description: "Error code"},
            details: %Schema{type: :object, description: "Additional error details", nullable: true}
          }
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "message" => "Resource not found",
          "code" => "not_found",
          "details" => %{}
        }
      }
    })
  end

  defmodule ValidationErrorResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "ValidationErrorResponse",
      description: "Validation error response",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            message: %Schema{type: :string, description: "Error message"},
            code: %Schema{type: :string, description: "Error code"},
            details: %Schema{
              type: :object,
              description: "Validation error details",
              additionalProperties: %Schema{
                type: :array,
                items: %Schema{type: :string}
              }
            }
          }
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "message" => "Validation failed",
          "code" => "validation_error",
          "details" => %{
            "name" => ["can't be blank"],
            "email" => ["has invalid format"]
          }
        }
      }
    })
  end

  defmodule SuccessResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "SuccessResponse",
      description: "Generic success response",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            message: %Schema{type: :string, description: "Success message"}
          }
        }
      },
      example: %{
        "data" => %{
          "message" => "Operation completed successfully"
        }
      }
    })
  end

  defmodule NoContentResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "NoContentResponse",
      description: "No content response (successful deletion)",
      type: :object,
      example: %{}
    })
  end
end
