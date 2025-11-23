# Audio Generation - Quick Start Guide

## Setup (One-Time)

### 1. Get Replicate API Key
```bash
# Sign up at https://replicate.com
# Get your API token from: https://replicate.com/account/api-tokens
```

### 2. Configure Environment
```bash
export REPLICATE_API_KEY="r8_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### 3. Run Migration
```bash
cd backend
mix ecto.migrate
```

### 4. Verify FFmpeg
```bash
ffmpeg -version  # Should show libmp3lame support
ffprobe -version # Should be installed
```

## Basic Usage

### Start Audio Generation
```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{"job_id": "123"}'
```

### Check Status
```bash
curl http://localhost:4000/api/v3/audio/status/123
```

### Download Audio
```bash
curl http://localhost:4000/api/v3/audio/123/download -o audio.mp3
```

## Common Scenarios

### 1. Generate Audio Only (No Video Merge)
```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "merge_with_video": false
    }
  }'
```

### 2. Generate and Merge with Video
```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "merge_with_video": true,
      "sync_mode": "trim"
    }
  }'
```

### 3. Custom Music Style
```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "prompt": "Epic orchestral music with dramatic crescendos"
    }
  }'
```

### 4. Longer Fade Transitions
```bash
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{
    "job_id": "123",
    "audio_params": {
      "fade_duration": 2.5
    }
  }'
```

## Parameters Reference

### `sync_mode` Options
- `"trim"` - Cut audio to match video length (default)
- `"stretch"` - Time-stretch audio (may sound unnatural)
- `"compress"` - Tempo adjustment (limited to 0.5-2.0x)

### `error_strategy` Options
- `"continue_with_silence"` - Keep going with silent segments (default)
- `"halt"` - Stop on first error

### `fade_duration`
- Default: `1.0` (seconds)
- Range: `0.0` to `5.0` recommended

## Workflow Integration

### Option 1: After Video Stitching
```elixir
# After video is complete
AudioWorker.generate_job_audio(job_id, %{
  merge_with_video: true,
  sync_mode: :trim
})
```

### Option 2: Independent Audio Generation
```elixir
# Generate audio without video
AudioWorker.generate_job_audio(job_id, %{
  merge_with_video: false
})
```

### Option 3: Manual Scene Audio
```elixir
# Single scene
scene = %{
  "title" => "Scene 1",
  "description" => "Dramatic opening scene",
  "duration" => 5
}

AudioWorker.generate_scene_audio(scene, %{
  prompt: "Epic music"
})
```

## Monitoring

### Check Logs
```bash
# Real-time logs
tail -f log/dev.log | grep -E "(MusicgenService|AudioWorker|AudioController)"
```

### Progress Tracking
```elixir
job = Repo.get(Job, job_id)
job.progress
# Returns:
# %{
#   "audio_status" => "completed",
#   "audio_generated_at" => "2024-01-15T10:30:45Z",
#   "audio_size" => 1234567,
#   "video_with_audio" => true
# }
```

## Troubleshooting

### No API Key Warning
```
[MusicgenService] No Replicate API key configured, using silence
```
**Fix:** Set `REPLICATE_API_KEY` environment variable

### FFmpeg Not Found
```
[MusicgenService] FFmpeg merge failed
```
**Fix:** Install FFmpeg with `brew install ffmpeg` (macOS) or `apt install ffmpeg` (Linux)

### Timeout Error
```
[MusicgenService] Audio generation timed out
```
**Fix:** Reduce scene count or check Replicate API status

### Job Has No Storyboard
```
{"error": "Job has no storyboard - cannot generate audio"}
```
**Fix:** Ensure job has scenes generated before calling audio endpoint

## Performance Tips

1. **Batch Processing:** Process multiple jobs sequentially rather than parallel
2. **Scene Count:** 5-10 scenes is optimal (50-100 seconds total)
3. **Caching:** Reuse audio for similar scenes if possible
4. **Background Jobs:** Use Task.Supervisor for production

## Testing Without API Key

The system automatically falls back to silence generation:

```bash
# Unset API key for testing
unset REPLICATE_API_KEY

# This will generate silent MP3 files instead
curl -X POST http://localhost:4000/api/v3/audio/generate-scenes \
  -H "Content-Type: application/json" \
  -d '{"job_id": "123"}'
```

## Production Checklist

- [ ] Set `REPLICATE_API_KEY` in production environment
- [ ] Verify FFmpeg and FFprobe are installed
- [ ] Configure proper logging level
- [ ] Set up monitoring for audio generation failures
- [ ] Consider implementing job queue (Oban)
- [ ] Set database connection pool size appropriately
- [ ] Configure proper timeout values
- [ ] Set up error alerting (e.g., Sentry)

## API Rate Limits

Replicate API:
- Check current limits at https://replicate.com/pricing
- Consider implementing rate limiting in your application
- Use error_strategy: "continue_with_silence" for graceful degradation

## Cost Estimation

Replicate MusicGen pricing (as of 2024):
- ~$0.01 per 10 seconds of audio generated
- For 5 scenes × 5 seconds = 25 seconds = ~$0.025 per job
- Monitor usage at https://replicate.com/account/billing

## Support

For issues or questions:
1. Check AUDIO_WORKFLOW.md for detailed documentation
2. Review logs for error messages
3. Verify configuration and dependencies
4. Check Replicate API status: https://status.replicate.com

## Next Steps

1. Test with a sample job
2. Customize music prompts for your use case
3. Integrate into your workflow
4. Monitor performance and costs
5. Consider implementing caching strategies
