defmodule BackendWeb.Schemas.CommonSchemas do
  @moduledoc """
  Common OpenAPI schemas shared across the API.
  """

  alias OpenApiSpex.Schema

  defmodule ErrorResponse do
    @moduledoc """
    Standard error response schema following JSON:API spec.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Standard error response",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              status: %Schema{type: :string, description: "HTTP status code"},
              code: %Schema{type: :string, description: "Application-specific error code"},
              title: %Schema{type: :string, description: "Short error summary"},
              detail: %Schema{type: :string, description: "Detailed error message"},
              source: %Schema{
                type: :object,
                properties: %{
                  pointer: %Schema{type: :string, description: "JSON Pointer to the error source"},
                  parameter: %Schema{type: :string, description: "Query parameter that caused the error"}
                }
              },
              meta: %Schema{
                type: :object,
                description: "Additional metadata",
                additionalProperties: true
              }
            },
            required: [:title]
          }
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "status" => "422",
            "code" => "validation_error",
            "title" => "Validation Failed",
            "detail" => "The provided asset_id does not exist",
            "source" => %{
              "pointer" => "/data/attributes/asset_id"
            }
          }
        ]
      }
    })
  end

  defmodule NotFoundResponse do
    @moduledoc """
    404 Not Found response schema.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NotFoundResponse",
      description: "Resource not found response",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            message: %Schema{type: :string},
            code: %Schema{type: :string, default: "not_found"},
            resource: %Schema{type: :string}
          },
          required: [:message, :code]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "message" => "Job not found",
          "code" => "not_found",
          "resource" => "job"
        }
      }
    })
  end

  defmodule ValidationErrorResponse do
    @moduledoc """
    422 Validation Error response schema.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ValidationErrorResponse",
      description: "Validation error response",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            message: %Schema{type: :string},
            code: %Schema{type: :string, default: "validation_failed"},
            details: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  field: %Schema{type: :string},
                  message: %Schema{type: :string}
                }
              }
            }
          },
          required: [:message, :code]
        }
      },
      required: [:error],
      example: %{
        "error" => %{
          "message" => "Validation failed",
          "code" => "validation_failed",
          "details" => [
            %{
              "field" => "asset_ids",
              "message" => "must contain at least one item"
            },
            %{
              "field" => "duration_seconds",
              "message" => "must be between 10 and 120"
            }
          ]
        }
      }
    })
  end

  defmodule SuccessResponse do
    @moduledoc """
    Generic success response schema.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SuccessResponse",
      description: "Generic success response",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        data: %Schema{
          type: :object,
          additionalProperties: true
        }
      },
      required: [:message],
      example: %{
        "message" => "Operation completed successfully",
        "data" => %{
          "id" => 123,
          "status" => "completed"
        }
      }
    })
  end

  defmodule PaginationMeta do
    @moduledoc """
    Pagination metadata schema.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PaginationMeta",
      description: "Pagination metadata",
      type: :object,
      properties: %{
        total: %Schema{type: :integer, description: "Total number of items"},
        page: %Schema{type: :integer, description: "Current page number", minimum: 1},
        per_page: %Schema{type: :integer, description: "Items per page", minimum: 1, maximum: 100},
        total_pages: %Schema{type: :integer, description: "Total number of pages"},
        has_next: %Schema{type: :boolean, description: "Whether there is a next page"},
        has_prev: %Schema{type: :boolean, description: "Whether there is a previous page"}
      },
      required: [:total, :page, :per_page, :total_pages],
      example: %{
        "total" => 250,
        "page" => 2,
        "per_page" => 50,
        "total_pages" => 5,
        "has_next" => true,
        "has_prev" => true
      }
    })
  end

  defmodule HealthCheckResponse do
    @moduledoc """
    Health check response schema.
    """
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthCheckResponse",
      description: "Health check response",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: [:healthy, :degraded, :unhealthy]},
        version: %Schema{type: :string, description: "API version"},
        timestamp: %Schema{type: :string, format: :"date-time"},
        services: %Schema{
          type: :object,
          properties: %{
            database: %Schema{type: :string, enum: [:up, :down]},
            redis: %Schema{type: :string, enum: [:up, :down]},
            replicate_api: %Schema{type: :string, enum: [:up, :down]},
            xai_api: %Schema{type: :string, enum: [:up, :down]}
          }
        }
      },
      required: [:status, :version, :timestamp],
      example: %{
        "status" => "healthy",
        "version" => "3.0.0",
        "timestamp" => "2025-11-23T12:34:55Z",
        "services" => %{
          "database" => "up",
          "redis" => "up",
          "replicate_api" => "up",
          "xai_api" => "up"
        }
      }
    })
  end
end