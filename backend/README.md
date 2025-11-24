# Backend - Video Generation API

Phoenix API backend for video generation using Replicate and XAI APIs.

## Setup

### Prerequisites
- Elixir 1.15 or later
- Erlang/OTP 24 or later

### Environment Variables
Copy `.env.example` to `.env` and configure:
```bash
cp .env.example .env
```

Required environment variables:
- `REPLICATE_API_KEY` - Your Replicate API key (get from https://replicate.com/account/api-tokens)
- `XAI_API_KEY` - Your XAI API key (get from https://x.ai/api)
- `PUBLIC_BASE_URL` - Publicly reachable base URL (ngrok in development, Fly URL in prod) so Replicate can fetch first/last-frame assets.
- `VIDEO_GENERATION_MODEL` - Default Replicate model (`veo3` or `hilua-2.5`) used for rendering; can be overridden per request.
- `REPLICATE_WEBHOOK_URL` *(optional)* - If you need Replicate to POST status callbacks, point this at a real HTTPS endpoint; leave blank to disable webhooks (recommended until a handler exists).
- `AUTO_GENERATE_AUDIO` *(optional, default: false)* - Set to `true` to automatically trigger MusicGen background audio once stitching finishes.
- `AUDIO_MERGE_WITH_VIDEO` *(optional, default: true)* - Controls whether the generated track is muxed into the stitched MP4 when auto-audio is enabled.
- `AUDIO_SYNC_MODE` *(optional, default: trim)* - How the merged track is aligned with the video (`trim`, `stretch`, or `compress`).
- `AUDIO_ERROR_STRATEGY` *(optional, default: continue_with_silence)* - Strategy for per-scene failures when generating audio (`continue_with_silence` or `halt`).
- `AUDIO_FAIL_ON_ERROR` *(optional, default: false)* - When `true`, any auto-audio failure marks the job as failed so callers can retry.

### Installation

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Database

This project uses SQLite3 with WAL (Write-Ahead Logging) mode for better concurrency:
- Development DB: `backend_dev.db` in the project root
- Test DB: `backend_test.db`
- Production DB: Configured via `DATABASE_PATH` environment variable

## End-to-End Video Pipeline

The pipeline mirrors the legacy Python service so the frontend can talk to the same set of endpoints:

1. **Create the Job**
   - From a campaign: `POST /api/v3/campaigns/:id/create-job`
   - Directly from assets: `POST /api/v3/jobs/from-image-pairs` or `/api/v3/jobs/from-property-photos`
   - The response contains `job_id`, `status: "pending"`, and generated storyboard data you can display before rendering.

2. **Approval Gate (required)**
   - Jobs stay in `pending` until the frontend (or an automated reviewer) explicitly approves them.
   - Call `POST /api/v3/jobs/:id/approve` to kick off rendering. If you call it twice or try to approve a job that already moved on, you’ll get a `422`.

3. **Rendering + Scene Processing**
   - After approval the `Coordinator` spins up sub-jobs, chooses the Replicate model (`veo3` or `hilua-2.5`/`hailuo-02`), and hands each scene to the `RenderWorker`.
   - Assets referenced in the storyboard are served via `/api/v3/assets/:asset_id/data`. Replicate uses those URLs (first/last frame) to render transitions; no auth header is required on that endpoint.
   - Scene prompts are fed to Replicate/XAI via the `scene_prompt/1` helper, which returns `scene["prompt"]` (or falls back to `description`, `title`, or a generic string). Whatever is in the storyboard's prompt field is what gets rendered (backend/lib/backend/workflow/render_worker.ex:439-447).
   - Webhook callbacks (if `REPLICATE_WEBHOOK_URL` is set) land at `POST /api/webhooks/replicate` and update sub-job state; otherwise the worker polls Replicate until completion.

4. **Progress + Status Updates**
   - Poll `GET /api/v3/jobs/:id` for high-level status. The payload includes `status`, `progress_percentage`, `current_stage`, the original `parameters`, and the storyboard.
   - If you need per-scene detail, call `GET /api/v3/jobs/:job_id/scenes` to see each scene’s status and rendered clip metadata.
   - `progress.stage` values move through `pending → starting_render → waiting_prediction → downloading_video → stitching → completed/failed`. When auto-audio is enabled the flow continues through `audio_generation_pending → audio_generation → audio_completed`.

5. **Downloading Results**
   - Combined video: `GET /api/v3/videos/:job_id/combined` (binary MP4). This endpoint streams the stitched output once the job hits `completed`.
   - Thumbnail preview: `GET /api/v3/videos/:job_id/thumbnail`
   - Individual clips: `GET /api/v3/videos/:job_id/clips/:filename` (and `/thumbnail` if you need per-clip stills).

6. **Automatic Music (optional)**
   - When `AUTO_GENERATE_AUDIO=true`, the coordinator automatically enqueues the MusicGen worker after stitching succeeds.
   - Progress transitions to `audio_generation` while Replicate runs, and the resulting MP3 is stored in `jobs.audio_blob`.
   - Set `AUDIO_MERGE_WITH_VIDEO=true` to have the final MP4 rewritten with the new soundtrack; otherwise download the audio via `GET /api/v3/audio/:job_id/download`.
   - **Audio Segment Store**: MusicGen continuation across scenes uses an ETS-backed cache (`AudioSegmentStore`) to serve ephemeral audio clips when Replicate doesn't provide CDN URLs. Segments are automatically published at `GET /api/v3/audio/segments/:token` (no auth required). Tokens expire after 30 minutes by default; tune retention with `AUDIO_SEGMENT_TTL` if your jobs run longer.

7. **Frontend Checklist**
   - Capture the `job_id` returned from the creation call.
   - Surface the storyboard and assets for a human review, then call `/jobs/:id/approve` when ready.
   - Poll `/jobs/:id` (or subscribe to webhooks if desired) until `status` becomes `completed`, then download from `/videos/:job_id/combined`.
   - On failure, the job payload’s `progress.error` field is populated; the frontend can retry by creating a new job with the same assets.

All endpoints are documented in `GET /api/openapi` for quick reference, and the response shapes intentionally match the previous Python implementation (camelCase fields for campaign/asset payloads).

## Utility Scripts

### Asset Blob Backfill
Production assets imported from Wander only store `source_url`s by default. If you need every asset persisted in SQLite (e.g., to avoid future CDN changes), run the bundled task inside the release:

```bash
# SSH into the Fly machine, then
cd /app
bin/backend eval "Backend.Tasks.AssetBackfill.run()"
```

Optional arguments:

- `limit: n` – only processes the first `n` assets (helpful for dry runs).
- `sleep_ms: 200` – inserts a delay between downloads to avoid hammering the source CDN.

The task logs each asset, downloads the bytes via `Req`, and updates `blob_data` along with metadata such as `blob_backfilled_at` and `blob_size_bytes`.

## Dependencies

Key dependencies:
- Phoenix 1.8.1 - Web framework
- Ecto + ecto_sqlite3 - Database layer with SQLite adapter
- Req 0.4 - HTTP client for API calls
- Jason 1.4 - JSON encoding/decoding
- Bandit - HTTP server

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
