# Product Requirements Document: Lean Elixir V3 Backend

## 1. Vision & Philosophy
The objective is to rewrite the existing Python/FastAPI/Luigi V3 backend into a **lean, high-performance Elixir/Phoenix application**.

**Core Principles:**
1.  **Zero Infrastructure Overhead:** Use **SQLite** for everything (Data, Job State, Binary Storage). No Postgres, No Redis, No S3.
2.  **Native Concurrency:** Replace Luigi/Celery with Elixir's native OTP (GenServer/Task/Supervisors) to handle parallel video generation workflows.
3.  **API Parity:** Strictly implement the V3 API contract used by the frontend.
4.  **Monolithic Simplicity:** All logic (HTTP serving, Background Processing, Database) runs in a single BEAM instance.

---

## 2. Technology Stack

| Component | Choice | Justification |
| :--- | :--- | :--- |
| **Language** | Elixir | Superior concurrency for parallel video rendering integration. |
| **Framework** | Phoenix (API Mode) | Robust HTTP layer. `--no-html --no-assets --no-mailer`. |
| **Database** | **SQLite3** (`ecto_sqlite3`) | Meets "Lean" requirement. Single file deployment (`scenes.db`). |
| **HTTP Client** | `Req` | Simple, high-level client for Replicate/OpenAI/xAI APIs. |
| **Media Proc** | `System.cmd("ffmpeg")` | Direct binary calls for stitching/thumbnails. No wrapper libraries. |
| **JSON** | `Jason` | Standard high-speed JSON parsing. |
| **Validation** | `Ecto.Changeset` | Replaces Pydantic for data validation. |

---

## 3. Architecture & Concurrency Model

Instead of the Python `BackgroundTasks` + `Luigi` setup, we will use an **OTP Supervision Tree**.

### 3.1. The Job Supervisor
A `DynamicSupervisor` that spawns a `GenServer` for each active Video Job.
*   **Python approach:** Poll database -> Create subprocess (Luigi).
*   **Elixir approach:** API Request -> Spawns `JobProcess` (GenServer) -> Manages state in memory & syncs to SQLite.

### 3.2. The "Workflow Engine" (Replacing Luigi)
Since we cannot use Oban (requires Postgres usually) effectively in a "lean" SQLite setup without friction, we will implement a simple **state-machine pattern** using Ecto schemas.

*   **Flow:**
    1.  **ImagePairJob:** User request -> Insert into SQLite (Status: `pending`).
    2.  **Orchestrator:** A singleton GenServer periodically checks for `pending` jobs (or is notified via PubSub).
    3.  **Parallel Execution:** Uses `Task.async_stream` to hit Replicate API for 7-10 scenes *simultaneously*.
    4.  **State Persistence:** Every step updates the SQLite `jobs` table immediately.

---

## 4. Database Schema (SQLite)

We will consolidate the Python schema into a clean Ecto schema.

### 4.1. `users`
*   `id` (Integer, PK)
*   `username`, `email`, `password_hash`
*   `api_key_hash`

### 4.2. `clients` & `campaigns`
Standard CRUD tables.
*   `clients`: `id` (UUID), `name`, `brand_guidelines` (Map/JSON).
*   `campaigns`: `id` (UUID), `client_id`, `name`, `brief` (Map/JSON).

### 4.3. `assets` (Unified Storage)
Replicates the "Consolidated Assets" migration from Python.
*   `id` (UUID, PK)
*   `type`: Enum (`image`, `video`, `audio`, `document`)
*   `blob_data`: **BLOB** (Actual binary file data).
*   `metadata`: Map/JSON (`width`, `height`, `duration`).
*   `source_url`: String (if downloaded from URL).
*   `campaign_id`: UUID (ForeignKey).

### 4.4. `jobs` (The Source of Truth)
*   `id`: Integer (PK)
*   `type`: Enum (`standard`, `image_pairs`, `property_video`)
*   `status`: Enum (`pending`, `processing`, `completed`, `failed`)
*   `parameters`: Map/JSON (Inputs from frontend).
*   `storyboard`: Map/JSON (The scenes list).
*   `progress`: Map/JSON (Percentage, current stage).
*   `result`: Map/JSON (Video URL, cost).

### 4.5. `sub_jobs` (For Parallel Rendering)
*   `id`: UUID
*   `job_id`: FK
*   `provider_id`: String (Replicate Prediction ID).
*   `status`: Enum.
*   `video_blob`: **BLOB** (The resulting clip).

---

## 5. Key Functionality & Implementation

### 5.1. Unified Asset Upload (`POST /api/v3/assets/unified`)
*   **Inputs:** File *or* URL.
*   **Logic:**
    1.  If File: Read into memory, validate magic bytes.
    2.  If URL: `Req.get(url)`, stream body into memory.
    3.  **Thumbnail:** If video, `System.cmd("ffmpeg", ["-i", "-", ...])` piping binary data.
    4.  **Storage:** `Repo.insert` into `assets` table (blob_data).

### 5.2. "From Image Pairs" Workflow (`POST /api/v3/jobs/from-image-pairs`)
*   **Logic:**
    1.  **Fetch:** Load all image assets for the campaign from SQLite.
    2.  **Select (AI):** Send asset list + campaign context to **xAI/Grok** via `Req`.
        *   *Prompt:* "Select 7 image pairs that tell a story..."
    3.  **Render (Parallel):**
        *   Parse Grok response.
        *   Create `sub_jobs` entries.
        *   Spawn `Task.async_stream` with concurrency: 10.
        *   Call **Replicate** (Veo3/Hailuo) for each pair.
        *   Poll Replicate for completion.
        *   Download result bytes -> Store in `sub_jobs.video_blob`.
    4.  **Stitch:**
        *   Extract all blobs to a temp directory `/tmp/job_123/`.
        *   Generate `concat.txt`.
        *   Run FFmpeg concat.
        *   Save final video to `jobs` table blob.

### 5.3. "Property Video" Workflow (`POST /api/v3/jobs/from-property-photos`)
*   **Logic:**
    *   Similar to Image Pairs but uses specific "Scene Types" (Arrival, Bedroom, etc.).
    *   **Validation:** Ensure Grok returns exactly 7 pairs matching the specific scene types defined in the Python `property_photo_selector.py`.

### 5.4. Audio Generation (MusicGen)
*   **Endpoint:** `/api/v3/audio/generate-scenes`
*   **Logic:**
    *   This requires **sequential** processing (Audio Continuation).
    *   Use `Enum.reduce_while` to chain calls to Replicate.
    *   Output of Scene 1 -> Input of Scene 2.
    *   Final merge with video using FFmpeg `afade` filters.

---

## 6. API Endpoints (V3 Implementation Specs)

All endpoints use `/api/v3` prefix.

| Method | Path | Description | Elixir Implementation Note |
| :--- | :--- | :--- | :--- |
| `POST` | `/assets/unified` | Upload/Download asset | Use `Plug.Upload` for files. Direct `Repo` insert. |
| `GET` | `/assets/:id/data` | Serve blob | `send_download` with correct content-type. |
| `POST` | `/jobs/from-image-pairs` | Start pair workflow | Spawns async Task/GenServer. Returns Job ID instantly. |
| `GET` | `/jobs/:id` | Poll status | Reads `jobs` table. Returns JSON with progress %. |
| `POST` | `/jobs/:id/approve` | Approve Storyboard | Updates job status to `rendering`. Triggers rendering process. |
| `GET` | `/videos/:id/data` | Serve final video | Stream BLOB from `generated_videos` table. |

---

## 7. Migration Plan (Python -> Elixir)

Since we are keeping SQLite but changing the application logic:

1.  **Schema Dump:**
    *   The Elixir app needs to initialize the SQLite DB.
    *   Create an Ecto migration that executes raw SQL matching the existing Python `schema.sql`.
    *   *Reason:* Allows the Elixir app to read existing Python-generated DBs if necessary (though starting fresh is safer).

2.  **Asset Migration (Optional):**
    *   If moving existing data, write a script to iterate Python `assets` table and ensure `blob_data` is populated (the Python code seemed to be transitioning to blobs).

3.  **Env Vars:**
    *   Keep `.env` compatibility: `REPLICATE_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`.

## 8. "Lean" Development Steps

1.  **Init:** `mix phx.new backend --no-html --no-assets --no-mailer --database sqlite3`.
2.  **Scaffold:** Generate Contexts (`mix phx.gen.json`) for Client, Campaign, Asset.
3.  **Blob Handling:** Implement the Controller logic to read/write binary data to SQLite.
4.  **The "Engine":** Implement module `Backend.Workflow.Coordinator` (GenServer).
    *   Handle the "Parallel Replicate" logic here.
    *   Implement exponential backoff for polling Replicate manually (simple recursive function with `Process.sleep`).
5.  **FFmpeg Wrapper:** Implement `Backend.Media.FFmpeg` module containing simple wrappers around `System.cmd("ffmpeg", args)`.

## 9. Risks & Mitigations

*   **SQLite Locking:** High concurrency writes (updating status of 10 sub-jobs simultaneously) might hit `SQLITE_BUSY`.
    *   *Mitigation:* Configure Ecto with `pool_size: 1` or `journal_mode: WAL` (Write-Ahead Logging) to handle concurrency better.
*   **Memory Usage:** Loading 50MB video blobs into RAM to serve them.
    *   *Mitigation:* Use `Repo.stream` or Phoenix `Stream` to send data in chunks to the client, avoiding loading the whole file into memory.
*   **Long Running Tasks:** If the server restarts, running jobs die.
    *   *Mitigation:* On startup (`Application.start`), query `jobs` table for `processing` status and restart/fail them. This mimics the "Recovery" logic seen in the Python `main.py`.
