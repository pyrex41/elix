# Audio Generation Workflow Documentation

## Overview

The Audio Generation Workflow provides automated background music generation for video scenes using Replicate's MusicGen API. The system supports sequential scene processing with audio continuation for seamless transitions.

## Architecture

### Components

1. **MusicgenService** (`lib/backend/services/musicgen_service.ex`)
   - Integrates with Replicate's MusicGen API
   - Handles audio generation, merging, and video synchronization
   - Provides fallback silence generation when API is unavailable

2. **AudioWorker** (`lib/backend/workflow/audio_worker.ex`)
   - Orchestrates sequential audio generation across scenes
   - Manages continuation tokens for seamless audio chaining
   - Handles error recovery with configurable strategies

3. **AudioController** (`lib/backend_web/controllers/api/v3/audio_controller.ex`)
   - Provides REST API endpoints for audio generation
   - Manages asynchronous processing
   - Returns status and download capabilities

## API Endpoints

### 1. Generate Audio for Scenes

**Endpoint:** `POST /api/v3/audio/generate-scenes`

Starts audio generation for all scenes in a job.

**Request Body:**
```json
{
  "job_id": "123",
  "audio_params": {
    "fade_duration": 1.5,
    "sync_mode": "trim",
    "merge_with_video": true,
    "error_strategy": "continue_with_silence",
    "prompt": "Upbeat cinematic music"
  }
}
```

**Parameters:**
- `job_id` (required): The job ID to generate audio for
- `audio_params` (optional): Audio generation configuration
  - `fade_duration` (default: 1.0): Fade duration in seconds between segments
  - `sync_mode` (default: "trim"): Audio/video sync strategy
    - `"trim"`: Trim audio to match video duration
    - `"stretch"`: Stretch audio to match video (may sound unnatural)
    - `"compress"`: Compress audio using tempo adjustment (0.5-2.0x range)
  - `merge_with_video` (default: false): Whether to merge audio with existing video
  - `error_strategy` (default: "continue_with_silence"): Error handling approach
    - `"continue_with_silence"`: Generate silence for failed scenes and continue
    - `"halt"`: Stop processing on first error
  - `prompt` (optional): Custom music generation prompt

**Response:**
```json
{
  "job_id": "123",
  "status": "processing",
  "message": "Audio generation started",
  "audio_status": {
    "started_at": "2024-01-15T10:30:00Z",
    "estimated_duration": "45s"
  }
}
```

### 2. Get Audio Status

**Endpoint:** `GET /api/v3/audio/status/:job_id`

Returns the current status of audio generation.

**Response:**
```json
{
  "job_id": "123",
  "audio_status": {
    "status": "completed",
    "generated_at": "2024-01-15T10:30:45Z",
    "size": 1234567,
    "merged_with_video": true,
    "error": null
  }
}
```

### 3. Download Generated Audio

**Endpoint:** `GET /api/v3/audio/:job_id/download`

Downloads the generated audio file (MP3 format).

**Response:** Binary audio data with appropriate headers

## Workflow Process

### Sequential Audio Generation

1. **Scene Processing:**
   - Scenes are processed sequentially using `Enum.reduce_while`
   - Each iteration generates audio for one scene
   - Continuation tokens are passed between scenes for seamless transitions

2. **Audio Chaining:**
   ```elixir
   # Pseudocode
   scenes
   |> Enum.reduce_while(initial_state, fn scene, state ->
     generate_audio(scene, state.previous_result)
     |> accumulate_segment()
     |> pass_continuation_to_next()
   end)
   ```

3. **Segment Merging:**
   - All audio segments are merged using FFmpeg
   - Fade effects are applied between segments:
     - Fade out at the end of each segment (except last)
     - Fade in at the start of each segment (except first)
   - Filter complex example:
     ```bash
     [0:a]afade=t=out:st=9:d=1[a0];
     [1:a]afade=t=in:st=0:d=1,afade=t=out:st=9:d=1[a1];
     [a0][a1]concat=n=2:v=0:a=1[out]
     ```

### Video-Audio Merging

When `merge_with_video: true` is set:

1. **Duration Sync:**
   - Video and audio durations are compared
   - Sync strategy is applied based on `sync_mode`:
     - **Trim:** Audio is trimmed to match video length
     - **Stretch:** Audio is time-stretched (may affect quality)
     - **Compress:** Audio tempo is adjusted (limited to 0.5-2.0x)

2. **FFmpeg Merging:**
   ```bash
   ffmpeg -i video.mp4 -i audio.mp3 \
          -c:v copy -c:a aac -b:a 192k \
          -shortest output.mp4
   ```

## Error Handling

### Strategy Options

1. **Continue with Silence** (default):
   - Failed scenes generate silent audio
   - Processing continues for remaining scenes
   - Final video has audio gaps instead of failures

2. **Halt on Error:**
   - Processing stops at first failure
   - Returns error to caller
   - Useful when audio quality is critical

### Fallback Mechanisms

1. **No API Key:**
   - System automatically falls back to silence generation
   - Uses FFmpeg to create silent MP3 files

2. **API Failures:**
   - Retry logic with exponential backoff (1s, 2s, 4s, 8s, max 10s)
   - Maximum 60 polling attempts (10 minutes total)
   - Graceful degradation to silence

3. **FFmpeg Failures:**
   - Errors are logged but don't crash the system
   - Audio is stored separately even if merge fails

## Database Schema

### Job Table Updates

Added `audio_blob` field to store generated audio:

```sql
ALTER TABLE jobs ADD COLUMN audio_blob BYTEA;
```

### Progress Tracking

Audio metadata is stored in `job.progress`:

```json
{
  "audio_status": "completed",
  "audio_generated_at": "2024-01-15T10:30:45Z",
  "audio_size": 1234567,
  "video_with_audio": true
}
```

## Configuration

### Environment Variables

Add to your configuration:

```elixir
# config/config.exs or config/runtime.exs
config :backend,
  replicate_api_key: System.get_env("REPLICATE_API_KEY")
```

### API Key Setup

1. Get a Replicate API key from https://replicate.com
2. Set the environment variable:
   ```bash
   export REPLICATE_API_KEY="your-api-key-here"
   ```

## Usage Examples

### Basic Usage

```bash
# Start audio generation
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "fade_duration": 1.5
    }
  }'

# Check status
curl http://localhost:4000/api/v3/audio/status/123

# Download audio
curl http://localhost:4000/api/v3/audio/123/download -o audio.mp3
```

### Advanced Usage with Video Merging

```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "fade_duration": 2.0,
      "sync_mode": "trim",
      "merge_with_video": true,
      "prompt": "Epic orchestral music with dramatic crescendos"
    }
  }'
```

### Custom Error Handling

```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "error_strategy": "halt"
    }
  }'
```

## MusicGen API Details

### Model Configuration

- **Model:** `meta/musicgen:671ac645ce5e552cc63a54a2bbff63fcf798043055d2dac5fc9e36a837eedcfb`
- **Version:** stereo-large
- **Output Format:** MP3
- **Normalization:** Loudness normalization enabled

### Prompt Engineering

The system automatically generates prompts based on scene descriptions:

- **Exciting/Dynamic scenes:** "upbeat and energetic"
- **Calm/Peaceful scenes:** "calm and peaceful"
- **Dramatic/Intense scenes:** "dramatic and intense"
- **Elegant/Luxury scenes:** "elegant and sophisticated"
- **Default:** "professional and engaging"

Example generated prompt:
```
"Cinematic background music, dramatic and intense, instrumental, seamless loop"
```

## Performance Considerations

### Timing

- **Per Scene:** ~10 seconds for API processing
- **Polling Interval:** 1s to 10s (exponential backoff)
- **Total Time:** Approximately `(number_of_scenes * 10s)`

### Resource Usage

- **Memory:** Audio blobs are stored in database (consider size limits)
- **Disk:** Temporary files are created and cleaned up automatically
- **Network:** Audio files are downloaded from Replicate CDN

## Testing

### Manual Testing

1. Create a job with scenes
2. Call the audio generation endpoint
3. Monitor progress using status endpoint
4. Download and verify audio file

### Integration Testing

See `test/backend_web/controllers/api/v3/audio_controller_test.exs` for comprehensive tests.

## Troubleshooting

### Common Issues

1. **"No Replicate API key configured"**
   - Solution: Set `REPLICATE_API_KEY` environment variable

2. **"Audio generation timed out"**
   - Cause: API taking longer than 10 minutes
   - Solution: Reduce scene count or increase timeout

3. **"FFmpeg merge failed"**
   - Cause: FFmpeg not installed or incompatible version
   - Solution: Install FFmpeg with libmp3lame support

4. **"Invalid audio output format"**
   - Cause: Replicate API returned unexpected format
   - Solution: Check API version and update model reference

### Debug Logging

Enable debug logging to see detailed workflow:

```elixir
# config/config.exs
config :logger, level: :debug
```

Look for log entries with:
- `[MusicgenService]` - API interactions
- `[AudioWorker]` - Workflow processing
- `[AudioController]` - Request handling

## Future Enhancements

Potential improvements:

1. **Streaming Audio Generation:** Generate and stream audio in real-time
2. **Audio Preview:** Generate short previews before full generation
3. **Custom Music Styles:** Support user-uploaded music samples
4. **Audio Analysis:** Detect beat timing and sync with video transitions
5. **Caching:** Cache generated audio for similar scenes
6. **Background Jobs:** Use Oban or similar for better job management

## License

This implementation uses:
- Replicate API (requires API key and billing)
- FFmpeg (LGPL/GPL, ensure compliance)
- MusicGen model (Meta, check license terms)
