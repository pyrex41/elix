# Video Stitching Implementation

## Overview

The video stitching functionality combines multiple rendered video segments into a single final video using FFmpeg. This is implemented through two main modules:

1. **FFmpegService** - Low-level FFmpeg operations
2. **StitchWorker** - High-level stitching workflow orchestration

## Architecture

### FFmpegService (`lib/backend/services/ffmpeg_service.ex`)

Provides core FFmpeg operations:

- **`check_ffmpeg_available/0`** - Verifies FFmpeg installation
- **`extract_video_blobs/2`** - Extracts video blobs to temp files
- **`generate_concat_file/2`** - Creates FFmpeg concat.txt manifest
- **`stitch_videos/2`** - Executes FFmpeg concat command
- **`read_video_file/1`** - Reads stitched video into binary
- **`cleanup_temp_files/1`** - Removes temporary files

### StitchWorker (`lib/backend/workflow/stitch_worker.ex`)

Orchestrates the complete stitching workflow:

1. Validates all sub_jobs are completed
2. Creates temporary directory `/tmp/job_<id>/`
3. Extracts video blobs to numbered files
4. Generates concat.txt with proper ordering
5. Executes FFmpeg stitching
6. Stores result in job.result field
7. Cleans up temporary files
8. Updates job status to 'completed'

## Workflow Integration

### Coordinator Integration

The `Coordinator` module has been enhanced to trigger stitching automatically:

```elixir
# When a sub_job completes rendering, notify the coordinator
Backend.Workflow.Coordinator.sub_job_completed(job_id, sub_job_id)

# Coordinator checks if all sub_jobs are done
# If yes, spawns async task to stitch videos
# If no, waits for more completions
```

### Progress Tracking

The stitching process updates job progress through several stages:

- **75%** - "all_renders_complete" - All rendering done, starting stitch
- **80%** - "stitching_videos" - FFmpeg stitching in progress
- **100%** - "completed" - Final video ready

## FFmpeg Command

The service uses FFmpeg's concat demuxer for efficient video concatenation:

```bash
ffmpeg -f concat -safe 0 -i concat.txt -c copy -y output.mp4
```

**Flags:**
- `-f concat` - Use concat demuxer
- `-safe 0` - Allow absolute file paths
- `-i concat.txt` - Input manifest file
- `-c copy` - Copy streams without re-encoding (fast)
- `-y` - Overwrite output if exists

## Concat File Format

The concat.txt file lists videos in order:

```
file '/tmp/job_123/scene_1.mp4'
file '/tmp/job_123/scene_2.mp4'
file '/tmp/job_123/scene_3.mp4'
```

## Error Handling

### FFmpeg Not Available
- **Detection**: System checks for FFmpeg on startup
- **Response**: Fails job with clear error message
- **Fix**: Install FFmpeg: `brew install ffmpeg` (macOS)

### Missing Video Blobs
- **Detection**: Checks each sub_job.video_blob field
- **Response**: Skips missing blobs or fails gracefully
- **Option**: Use `partial_stitch/2` to stitch available videos

### Corrupted Videos
- **Detection**: FFmpeg will error during concat
- **Response**: Logs FFmpeg error output and fails job
- **Recovery**: Retry failed sub_jobs using RenderWorker

### Disk Space Issues
- **Detection**: Checks available space in /tmp before starting
- **Response**: Fails early if < 100MB available
- **Cleanup**: Always cleans temp files, even on failure

## Usage Examples

### Normal Stitching (All Sub_jobs Complete)

```elixir
# Triggered automatically by Coordinator when all renders complete
# Or manually:
{:ok, result_blob} = Backend.Workflow.StitchWorker.stitch_job(job_id)
```

### Partial Stitching (Some Failed)

```elixir
# Stitch only completed sub_jobs, skip failed ones
{:ok, result_blob} = Backend.Workflow.StitchWorker.partial_stitch(job_id, %{skip_failed: true})
```

## Memory Optimization

### File Streaming
- Videos are written to disk, not held in memory during concat
- FFmpeg streams data efficiently
- Only final result is read into memory

### Immediate Cleanup
- Temp files deleted immediately after reading result
- Cleanup happens even on failures
- Uses `/tmp` which may be tmpfs (RAM-backed) on some systems

### Large Video Handling
- FFmpeg handles videos of any size
- Binary data stored in PostgreSQL BYTEA field
- Consider external storage for very large results (future enhancement)

## Performance Characteristics

### Speed
- **Fast**: No re-encoding (copy mode)
- Depends on disk I/O speed
- Typical: < 1 second per minute of video

### Resource Usage
- **CPU**: Minimal (copy mode, no encoding)
- **Memory**: ~100-200MB for moderate videos
- **Disk**: 2x total video size (temp + output)

## Monitoring and Logging

All operations log at appropriate levels:

```elixir
# Info - Major workflow steps
[StitchWorker] Starting video stitching for job 123
[FFmpegService] FFmpeg stitching completed successfully

# Debug - Detailed operations
[FFmpegService] Extracted scene_1.mp4 (5.23 MB)
[FFmpegService] Generated concat file at /tmp/job_123/concat.txt

# Error - Failures with context
[StitchWorker] FFmpeg stitching failed: {:ffmpeg_failed, 1, "..."}
[FFmpegService] Failed to read file: :enoent
```

## Testing

### Manual Test

```elixir
# In IEx console:
iex> alias Backend.Services.FfmpegService

# Check FFmpeg
iex> FfmpegService.check_ffmpeg_available()
{:ok, "4.4.2"}

# Test with real job
iex> job = Backend.Repo.get(Backend.Schemas.Job, 1)
iex> Backend.Workflow.StitchWorker.stitch_job(job.id)
```

### Requirements
- FFmpeg must be installed and in PATH
- Sufficient disk space in /tmp
- Valid sub_jobs with video_blob data

## Future Enhancements

1. **Streaming Large Files** - Chunk reading for videos > 100MB
2. **External Storage** - S3/R2 integration for large results
3. **Video Validation** - Pre-check videos for compatibility
4. **Custom Transitions** - Add crossfades between scenes
5. **Progress Callbacks** - Real-time FFmpeg progress parsing
6. **Retry Logic** - Automatic retry on transient failures
7. **Quality Optimization** - Smart re-encoding when needed

## Troubleshooting

### "FFmpeg not available"
- Check: `which ffmpeg`
- Install: `brew install ffmpeg` (macOS) or `apt-get install ffmpeg` (Linux)
- Verify: `ffmpeg -version`

### "Insufficient disk space"
- Check: `df -h /tmp`
- Clean: Old temp directories may remain if crashes occurred
- Fix: `rm -rf /tmp/job_*`

### "Output file not created"
- Check FFmpeg logs in application output
- Verify input videos are valid: `ffmpeg -i scene_1.mp4`
- Ensure videos have compatible codecs

### "Stitching takes too long"
- Normal for large videos (1GB+ each)
- Copy mode is fast; if slow, videos may be incompatible
- Check FFmpeg isn't re-encoding (look for "codec: copy" in logs)

## Dependencies

- **FFmpeg**: 4.0+ (tested with 4.4.2)
- **Elixir**: System.cmd/3 for FFmpeg execution
- **PostgreSQL**: BYTEA field for result storage
- **Disk**: Sufficient space in /tmp

## API Reference

See module documentation in:
- `Backend.Services.FfmpegService`
- `Backend.Workflow.StitchWorker`
- `Backend.Workflow.Coordinator`
