# Workflow Coordinator

## Overview

The Workflow Coordinator is a singleton GenServer that manages job orchestration for the video generation pipeline. It handles job approval, tracks job states, spawns processing tasks, and recovers interrupted workflows on startup.

## Architecture

### Components

1. **Backend.Workflow.Coordinator** - GenServer that coordinates all job workflows
2. **Backend.Schemas.Job** - Ecto schema for jobs table
3. **BackendWeb.Api.V3.JobController** - REST API endpoints for job management
4. **Phoenix.PubSub** - Event broadcasting for job state changes

### Job States

Jobs progress through the following states:

- `:pending` - Job created, waiting for approval
- `:approved` - Job approved, about to start processing
- `:processing` - Job is actively being processed
- `:completed` - Job finished successfully
- `:failed` - Job encountered an error

## Features

### 1. Job Approval

Jobs must be explicitly approved before processing begins. This allows for:

- Manual review of job parameters
- Cost estimation before processing
- Queue management and prioritization

**API Endpoint:**
```
POST /api/v3/jobs/:id/approve
```

**Example:**
```bash
curl -X POST http://localhost:4000/api/v3/jobs/123/approve
```

**Response:**
```json
{
  "message": "Job approved successfully",
  "job_id": 123,
  "status": "approved"
}
```

### 2. Job Status Polling

Monitor job progress in real-time:

**API Endpoint:**
```
GET /api/v3/jobs/:id
```

**Example:**
```bash
curl http://localhost:4000/api/v3/jobs/123
```

**Response:**
```json
{
  "job_id": 123,
  "type": "image_pairs",
  "status": "processing",
  "progress_percentage": 45,
  "current_stage": "rendering",
  "parameters": {...},
  "storyboard": {...},
  "inserted_at": "2025-11-22T12:00:00Z",
  "updated_at": "2025-11-22T12:05:00Z"
}
```

### 3. PubSub Integration

The Coordinator subscribes to and broadcasts events on the following topics:

- `jobs:created` - When a new job is created
- `jobs:approved` - When a job is approved
- `jobs:completed` - When a job finishes processing

**Subscribing to Events:**
```elixir
Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:completed")

# Handle events
def handle_info({:job_completed, job_id}, state) do
  # Process completion event
end
```

### 4. Startup Recovery

On startup, the Coordinator automatically:

1. Queries for jobs in `:processing` state
2. Resumes processing for each interrupted job
3. Updates progress to indicate resumption

This ensures no jobs are lost due to server restarts or crashes.

### 5. Job Tracking

The Coordinator maintains internal state tracking:

- **active_jobs** - Map of currently active jobs
- **processing_tasks** - Map of async tasks processing jobs

This allows for:
- Job cancellation (future feature)
- Resource management
- Concurrent job limits

## Usage

### Starting the Coordinator

The Coordinator is automatically started by the application supervisor:

```elixir
# In lib/backend/application.ex
children = [
  # ... other children
  Backend.Workflow.Coordinator,
  # ... more children
]
```

### Client API

The Coordinator provides a clean client API:

```elixir
# Approve a job
Backend.Workflow.Coordinator.approve_job(job_id)

# Update job progress
Backend.Workflow.Coordinator.update_progress(job_id, %{
  percentage: 50,
  stage: "rendering"
})

# Complete a job
Backend.Workflow.Coordinator.complete_job(job_id, result_blob)

# Fail a job
Backend.Workflow.Coordinator.fail_job(job_id, "Error message")
```

### Processing Jobs

Job processing is handled asynchronously using `Task.async`:

```elixir
defp spawn_job_processing(job, state) do
  # Update status to processing
  changeset = Job.changeset(job, %{
    status: :processing,
    progress: %{percentage: 5, stage: "initializing"}
  })

  Repo.update(changeset)

  # Spawn async task
  task = Task.async(fn -> process_job(job) end)

  # Track the task
  new_state = put_in(state.processing_tasks[job.id], task)

  new_state
end
```

## Integration Points

### Database Schema

Jobs table structure:

```sql
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL,
  status TEXT NOT NULL,
  parameters TEXT,  -- JSON
  storyboard TEXT,  -- JSON
  progress TEXT,    -- JSON
  result BLOB,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

### Task.async_stream (Future)

For Task 8, rendering uses `Task.async_stream` with a configurable concurrency cap (`REPLICATE_MAX_CONCURRENCY`, default `4`) and a per-scene stagger (`REPLICATE_START_DELAY_MS`, default `1000`) so we overlap jobs without sending four identical requests at the exact same millisecond:

```elixir
max_concurrency = Application.get_env(:backend, :replicate_max_concurrency, 4)
start_delay_ms = Application.get_env(:backend, :replicate_start_delay_ms, 1_000)

sub_jobs
|> Task.async_stream(
  &process_sub_job(&1, %{start_delay_ms: start_delay_ms}),
  max_concurrency: max(1, max_concurrency)
)
|> Enum.to_list()
```

## Testing

### Unit Tests

```bash
mix test test/backend/workflow/coordinator_test.exs
```

Tests cover:
- GenServer lifecycle
- Job approval workflow
- Progress updates
- Job completion/failure
- Startup recovery
- PubSub integration

### Integration Tests

```bash
mix test test/backend_web/controllers/api/v3/job_controller_test.exs
```

Tests cover:
- API endpoint functionality
- Error handling
- Workflow integration
- Event broadcasting

## Error Handling

The Coordinator handles errors gracefully:

1. **Invalid job ID** - Returns error response, no state change
2. **Database failures** - Logs error, maintains current state
3. **Task crashes** - Caught by monitor, job marked as failed
4. **PubSub failures** - Logged, processing continues

## Monitoring

Key log messages to monitor:

```
[Workflow.Coordinator] Starting Workflow Coordinator
[Workflow.Coordinator] Recovering interrupted jobs
[Workflow.Coordinator] Job approved: 123
[Workflow.Coordinator] Spawning processing task for job 123
[Workflow.Coordinator] Job 123 marked as completed
[Workflow.Coordinator] Task failed for job 123: reason
```

## Future Enhancements

1. **Job Cancellation** - Allow cancelling in-progress jobs
2. **Retry Logic** - Automatic retry for failed jobs
3. **Priority Queue** - Process high-priority jobs first
4. **Rate Limiting** - Limit concurrent job processing
5. **Job Dependencies** - Chain jobs together
6. **Webhook Notifications** - Notify external systems on completion

## Related Tasks

- Task 8: Implement Parallel Rendering with Replicate API
- Task 9: Implement Video Stitching with FFmpeg
- Task 11: Implement Scene Management API
