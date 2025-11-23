# Scene Management API Documentation

## Overview
The Scene Management API provides comprehensive CRUD operations for managing job scenes (sub_jobs) in the video generation workflow. Each scene represents an individual video clip that will be combined into the final video output.

## Base URL
```
/api/v3/jobs/:job_id/scenes
```

## Authentication
Currently, no authentication is required. This should be added in future updates.

## Endpoints

### 1. List All Scenes
**Endpoint:** `GET /api/v3/jobs/:job_id/scenes`

**Description:** Retrieves all scenes associated with a specific job.

**Parameters:**
- `job_id` (path parameter): The ID of the parent job

**Response (200 OK):**
```json
{
  "job_id": 123,
  "total_scenes": 5,
  "completed_scenes": 3,
  "progress_percentage": 60.0,
  "scenes": [
    {
      "id": "uuid-1",
      "status": "completed",
      "provider_id": "replicate-xyz",
      "has_video": true,
      "inserted_at": "2025-01-15T10:30:00Z",
      "updated_at": "2025-01-15T10:35:00Z"
    },
    ...
  ]
}
```

**Error Responses:**
- `404 Not Found`: Job not found

---

### 2. Get Specific Scene
**Endpoint:** `GET /api/v3/jobs/:job_id/scenes/:scene_id`

**Description:** Retrieves detailed information about a specific scene.

**Parameters:**
- `job_id` (path parameter): The ID of the parent job
- `scene_id` (path parameter): The ID of the scene

**Response (200 OK):**
```json
{
  "scene": {
    "id": "uuid-1",
    "job_id": 123,
    "status": "completed",
    "provider_id": "replicate-xyz",
    "has_video": true,
    "video_blob_size": 1048576,
    "inserted_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-01-15T10:35:00Z"
  },
  "job_id": 123,
  "job_status": "processing"
}
```

**Error Responses:**
- `404 Not Found`: Job or scene not found
- `422 Unprocessable Entity`: Scene does not belong to the specified job

---

### 3. Update Scene
**Endpoint:** `PUT /api/v3/jobs/:job_id/scenes/:scene_id`

**Description:** Updates a scene's data and notifies the Workflow Coordinator.

**Parameters:**
- `job_id` (path parameter): The ID of the parent job
- `scene_id` (path parameter): The ID of the scene

**Request Body:**
```json
{
  "status": "completed",
  "provider_id": "replicate-xyz"
}
```

**Allowed Fields:**
- `status`: One of `pending`, `processing`, `completed`, `failed`
- `provider_id`: External provider identifier for the scene

**Response (200 OK):**
```json
{
  "message": "Scene updated successfully",
  "scene": {
    "id": "uuid-1",
    "job_id": 123,
    "status": "completed",
    "provider_id": "replicate-xyz",
    "has_video": true,
    "video_blob_size": 1048576,
    "inserted_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-01-15T10:35:00Z"
  },
  "job_id": 123
}
```

**Error Responses:**
- `404 Not Found`: Job or scene not found
- `422 Unprocessable Entity`: Validation error or scene doesn't belong to job

**Side Effects:**
- Sends message to Workflow Coordinator about the scene update
- Recalculates overall job progress

---

### 4. Regenerate Scene
**Endpoint:** `POST /api/v3/jobs/:job_id/scenes/:scene_id/regenerate`

**Description:** Marks a scene for regeneration, resetting its status and clearing generated data.

**Parameters:**
- `job_id` (path parameter): The ID of the parent job
- `scene_id` (path parameter): The ID of the scene

**Response (200 OK):**
```json
{
  "message": "Scene marked for regeneration",
  "scene": {
    "id": "uuid-1",
    "job_id": 123,
    "status": "pending",
    "provider_id": null,
    "has_video": false,
    "video_blob_size": 0,
    "inserted_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-01-15T10:40:00Z"
  },
  "job_id": 123
}
```

**Error Responses:**
- `404 Not Found`: Job or scene not found
- `422 Unprocessable Entity`: Scene cannot be regenerated (e.g., currently processing) or doesn't belong to job

**Side Effects:**
- Resets scene status to `pending`
- Clears `provider_id` and `video_blob`
- Sends message to Workflow Coordinator to re-process the scene
- Recalculates overall job progress

---

### 5. Delete Scene
**Endpoint:** `DELETE /api/v3/jobs/:job_id/scenes/:scene_id`

**Description:** Deletes a scene and recalculates job progress.

**Parameters:**
- `job_id` (path parameter): The ID of the parent job
- `scene_id` (path parameter): The ID of the scene

**Response (200 OK):**
```json
{
  "message": "Scene deleted successfully",
  "scene_id": "uuid-1",
  "job_id": 123
}
```

**Error Responses:**
- `404 Not Found`: Job or scene not found
- `422 Unprocessable Entity`: Scene cannot be deleted (e.g., job is actively processing) or doesn't belong to job

**Side Effects:**
- Permanently removes the scene from the database
- Sends message to Workflow Coordinator about the deletion
- Recalculates overall job progress

---

## Workflow Coordinator Integration

All scene operations integrate with the `Backend.Workflow.Coordinator` GenServer:

### Messages Sent

1. **Scene Update:**
   ```elixir
   GenServer.cast(Coordinator, {:scene_updated, job_id, scene_id, status})
   ```

2. **Scene Regeneration:**
   ```elixir
   GenServer.cast(Coordinator, {:scene_regenerate, job_id, scene_id})
   ```

3. **Scene Deletion:**
   ```elixir
   GenServer.cast(Coordinator, {:scene_deleted, job_id, scene_id})
   ```

### Progress Calculation

After each scene operation (update, regenerate, delete), the controller automatically recalculates the job's overall progress:

```elixir
progress_data = %{
  percentage: <calculated_percentage>,
  stage: <current_stage>,
  total_scenes: <count>,
  completed_scenes: <count>,
  processing_scenes: <count>,
  failed_scenes: <count>
}

Coordinator.update_progress(job_id, progress_data)
```

## Scene Status Lifecycle

```
pending -> processing -> completed
                |
                v
              failed
                |
                v (regenerate)
              pending
```

## Example Usage

### Listing Scenes for a Job
```bash
curl -X GET http://localhost:4000/api/v3/jobs/123/scenes
```

### Getting Specific Scene Details
```bash
curl -X GET http://localhost:4000/api/v3/jobs/123/scenes/uuid-1
```

### Updating Scene Status
```bash
curl -X PUT http://localhost:4000/api/v3/jobs/123/scenes/uuid-1 \
  -H "Content-Type: application/json" \
  -d '{"status": "completed", "provider_id": "replicate-xyz"}'
```

### Regenerating a Failed Scene
```bash
curl -X POST http://localhost:4000/api/v3/jobs/123/scenes/uuid-1/regenerate
```

### Deleting a Scene
```bash
curl -X DELETE http://localhost:4000/api/v3/jobs/123/scenes/uuid-1
```

## Database Schema

### SubJob (Scene) Table
```elixir
schema "sub_jobs" do
  field :provider_id, :string
  field :status, Ecto.Enum, values: [:pending, :processing, :completed, :failed]
  field :video_blob, :binary

  belongs_to :job, Backend.Schemas.Job, type: :integer

  timestamps()
end
```

## Future Enhancements

1. **Authentication & Authorization**: Add user authentication and job ownership validation
2. **Batch Operations**: Support for bulk scene updates/deletions
3. **Scene Ordering**: Add ability to reorder scenes within a job
4. **Scene Preview**: Endpoint to retrieve scene video data
5. **Webhooks**: Notify external systems when scenes are updated
6. **Rate Limiting**: Prevent abuse of regenerate endpoint
7. **Soft Deletes**: Implement soft deletion with recovery capability
8. **Scene Metadata**: Store additional scene-specific metadata (prompts, parameters, etc.)
