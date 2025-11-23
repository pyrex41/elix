# OpenAPI Spec Auto-Generation Implementation

This document describes the OpenAPI Specification implementation for the Backend API.

## What Was Implemented

### 1. Dependencies
- Added `open_api_spex ~> 3.4` to `mix.exs`

### 2. API Specification Module
- Created `BackendWeb.ApiSpec` (`lib/backend_web/api_spec.ex`)
- Defines the OpenAPI 3.0 specification for the entire API
- Includes API key authentication scheme
- Auto-discovers all endpoints from the router

### 3. Schema Modules
Created OpenAPI schema modules for all API entities:

- **ClientSchemas** (`lib/backend_web/schemas/client_schemas.ex`)
  - Client
  - ClientRequest
  - ClientResponse
  - ClientsResponse
  - ClientStats

- **CampaignSchemas** (`lib/backend_web/schemas/campaign_schemas.ex`)
  - Campaign
  - CampaignRequest
  - CampaignResponse
  - CampaignsResponse
  - CampaignStats

- **AssetSchemas** (`lib/backend_web/schemas/asset_schemas.ex`)
  - Asset
  - AssetRequest
  - AssetFromUrlRequest
  - AssetFromUrlsRequest
  - AssetResponse
  - AssetsResponse

- **JobSchemas** (`lib/backend_web/schemas/job_schemas.ex`)
  - Job
  - ImagePairsRequest
  - PropertyPhotosRequest
  - JobResponse
  - Scene
  - SceneRequest
  - ScenesResponse
  - SceneResponse

- **CommonSchemas** (`lib/backend_web/schemas/common_schemas.ex`)
  - ErrorResponse
  - ValidationErrorResponse
  - SuccessResponse
  - NoContentResponse

### 4. Controller Documentation
Added `open_api_operation/1` callbacks to controllers:

- **ClientController** - All CRUD operations, campaigns listing, and stats
- **CampaignController** - All CRUD operations, assets listing, job creation, and stats
- **AssetController** - All CRUD operations, URL imports, and unified upload

Each operation includes:
- Tags for organization
- Summary and description
- Security requirements (API key)
- Request parameters and body schemas
- Response schemas for all status codes
- Example values

### 5. Router Updates
Updated `lib/backend_web/router.ex`:

- Added `OpenApiSpex.Plug.PutApiSpec` to `:api` and `:browser` pipelines
- Modified `/api/openapi` to use `OpenApiSpex.Plug.RenderSpec`
- Added `/swaggerui` route for interactive API documentation

### 6. Mix Task
Created `mix openapi.spec` task (`lib/mix/tasks/openapi.spec.ex`):
- Generates a static JSON file of the OpenAPI specification
- Usage: `mix openapi.spec [output_file]`
- Defaults to `openapi.json` if no file specified

## How to Use

### Install Dependencies

```bash
cd backend
mix deps.get
mix compile
```

### View the API Documentation

1. **Start the Phoenix server:**
   ```bash
   mix phx.server
   ```

2. **Access SwaggerUI:**
   - Open your browser to: `http://localhost:4000/swaggerui`
   - This provides an interactive interface to explore and test the API

3. **Get the JSON spec:**
   - Access: `http://localhost:4000/api/openapi`
   - Returns the complete OpenAPI 3.0 specification as JSON

### Generate Static Spec File

```bash
# Generate to default location (openapi.json)
mix openapi.spec

# Generate to custom location
mix openapi.spec priv/static/openapi.json
mix openapi.spec docs/api-spec.json
```

### Import into API Tools

The generated OpenAPI spec can be imported into:

- **Postman**: Import Collection → OpenAPI 3.0
- **Insomnia**: Import Data → OpenAPI 3.0
- **API Blueprint**: Use conversion tools
- **Code Generators**: Use `openapi-generator` CLI
- **Documentation Sites**: Upload to SwaggerHub, ReadMe.io, etc.

## Authentication

All authenticated endpoints require the `X-API-Key` header:

```bash
curl -H "X-API-Key: your-api-key-here" \
  http://localhost:4000/api/v3/clients
```

The SwaggerUI interface includes an "Authorize" button where you can set your API key for all requests.

## API Coverage

### Fully Documented Endpoints

- **Clients**
  - GET /api/v3/clients
  - POST /api/v3/clients
  - GET /api/v3/clients/:id
  - PUT /api/v3/clients/:id
  - DELETE /api/v3/clients/:id
  - GET /api/v3/clients/:id/campaigns
  - GET /api/v3/clients/:id/stats

- **Campaigns**
  - GET /api/v3/campaigns
  - POST /api/v3/campaigns
  - GET /api/v3/campaigns/:id
  - PUT /api/v3/campaigns/:id
  - DELETE /api/v3/campaigns/:id
  - GET /api/v3/campaigns/:id/assets
  - GET /api/v3/campaigns/:id/stats
  - POST /api/v3/campaigns/:id/create-job

- **Assets**
  - GET /api/v3/assets
  - POST /api/v3/assets
  - GET /api/v3/assets/:id
  - DELETE /api/v3/assets/:id
  - POST /api/v3/assets/from-url
  - POST /api/v3/assets/from-urls
  - POST /api/v3/assets/unified

### Endpoints to Document (Future)

To complete the API documentation, add `open_api_operation/1` callbacks to:

- `JobController` (approve, show)
- `JobCreationController` (from_image_pairs, from_property_photos)
- `SceneController` (index, show, update, regenerate, delete)
- `VideoController` (combined, thumbnail, clip, clip_thumbnail)
- `AudioController` (generate_scenes, status, download)

Follow the same pattern as the existing controllers.

## Validation (Optional)

To add request/response validation, you can use `OpenApiSpex.Plug.CastAndValidate`:

```elixir
defmodule BackendWeb.Api.V3.ClientController do
  use BackendWeb, :controller

  # Add this plug to validate all requests
  plug OpenApiSpex.Plug.CastAndValidate

  # ... rest of controller code
end
```

This will:
- Validate request parameters against schemas
- Cast params to proper Elixir types
- Return 422 errors for invalid requests
- Provide detailed error messages

## Testing

You can test schema validations in your tests:

```elixir
use ExUnit.Case
import OpenApiSpex.Test.Assertions

test "Client schema validates correctly" do
  api_spec = BackendWeb.ApiSpec.spec()
  client = %{
    "id" => "123e4567-e89b-12d3-a456-426614174000",
    "name" => "Acme Corp",
    "inserted_at" => "2024-01-01T00:00:00Z",
    "updated_at" => "2024-01-01T00:00:00Z"
  }
  assert_schema(client, "Client", api_spec)
end
```

## Troubleshooting

### Compilation Errors

If you encounter compilation errors after installing:

1. Clean build artifacts:
   ```bash
   mix clean
   mix compile
   ```

2. Check for missing aliases in controllers - all controller modules using OpenAPI must alias:
   ```elixir
   alias OpenApiSpex.Operation
   alias BackendWeb.Schemas.{...}
   ```

### Missing Endpoints

If endpoints don't appear in the spec:

1. Verify the controller has the `open_api_operation/1` callback
2. Ensure operation functions are defined (e.g., `index_operation/0`)
3. Check that the router uses the correct controller module name

### SwaggerUI Not Loading

1. Ensure the `:browser` pipeline includes `OpenApiSpex.Plug.PutApiSpec`
2. Check that `/api/openapi` returns valid JSON
3. Verify JavaScript assets can load from cdnjs.cloudflare.com

## Further Enhancements

Potential improvements for the future:

1. **Add validation plugs** to automatically validate requests
2. **Document remaining controllers** (Jobs, Scenes, Videos, Audio)
3. **Add response examples** to all schemas
4. **Create test helpers** to validate API responses match schemas
5. **Add deprecation notices** for old endpoints
6. **Version the API** with multiple spec files
7. **Generate client SDKs** using openapi-generator
8. **Add webhooks documentation** for the Replicate webhook

## Resources

- [OpenApiSpex Documentation](https://hexdocs.pm/open_api_spex/)
- [OpenAPI Specification](https://swagger.io/specification/)
- [SwaggerUI](https://swagger.io/tools/swagger-ui/)
- [OpenAPI Generator](https://openapi-generator.tech/)
