# FFmpeg Service - Quick Reference

## Installation

### macOS
```bash
brew install ffmpeg
```

### Linux (Ubuntu/Debian)
```bash
sudo apt-get update
sudo apt-get install ffmpeg
```

### Verify Installation
```bash
ffmpeg -version
# Should show version 4.0 or higher
```

## Basic Usage

### Check FFmpeg Availability
```elixir
alias Backend.Services.FfmpegService

FfmpegService.check_ffmpeg_available()
# => {:ok, "4.4.2"}
```

### Stitch Videos for a Job
```elixir
alias Backend.Workflow.StitchWorker

# Automatic (triggered by Coordinator after rendering)
# No manual intervention needed

# Manual (if needed)
StitchWorker.stitch_job(job_id)
# => {:ok, binary_video_data}

# Partial stitching (skip failed sub_jobs)
StitchWorker.partial_stitch(job_id, %{skip_failed: true})
# => {:ok, binary_video_data}
```

## How It Works

1. **Extract**: Sub_job video blobs → `/tmp/job_<id>/scene_N.mp4`
2. **Generate**: Create `concat.txt` with file list
3. **Stitch**: Execute `ffmpeg -f concat -safe 0 -i concat.txt -c copy output.mp4`
4. **Store**: Read output → `job.result` field
5. **Cleanup**: Remove `/tmp/job_<id>/` directory

## Troubleshooting

### Error: "FFmpeg not available"
**Cause**: FFmpeg not installed or not in PATH
**Fix**: Install FFmpeg (see above) and restart server

### Error: "Insufficient disk space"
**Cause**: Less than 100MB free in `/tmp`
**Fix**: Clean up old temp files: `rm -rf /tmp/job_*`

### Error: "Output file not created"
**Cause**: Video codec incompatibility or corrupted input
**Fix**: Check FFmpeg logs, verify input videos are valid

### Stitching is slow
**Cause**: Videos have incompatible codecs, FFmpeg is re-encoding
**Expected**: < 1 second per minute of video in copy mode
**Fix**: Ensure all input videos have same codec/resolution

## Monitoring

### Check Logs
```bash
# Application logs show stitching progress
tail -f backend.log | grep -E "(StitchWorker|FFmpegService)"
```

### Expected Log Flow
```
[StitchWorker] Starting video stitching for job 123
[StitchWorker] Found 3 sub_jobs for job 123
[FFmpegService] Extracted scene_1.mp4 (5.23 MB)
[FFmpegService] Extracted scene_2.mp4 (4.87 MB)
[FFmpegService] Extracted scene_3.mp4 (6.11 MB)
[FFmpegService] Generated concat file at /tmp/job_123/concat.txt
[FFmpegService] Starting FFmpeg stitching
[FFmpegService] FFmpeg stitching completed successfully
[StitchWorker] Stitched video created: 16.21 MB
[StitchWorker] Successfully completed stitching for job 123
```

## Performance Tips

### Disk Space
- Ensure `/tmp` has enough space (2x total video size)
- Consider mounting `/tmp` as tmpfs for faster I/O

### Memory
- Current: Entire result loaded into memory
- Future: Stream to external storage for >1GB results

### Speed
- Copy mode is fast (no re-encoding)
- Ensure input videos have compatible codecs
- Use SSD for `/tmp` directory

## API Reference

### FFmpegService Functions

| Function | Purpose | Returns |
|----------|---------|---------|
| `check_ffmpeg_available/0` | Verify FFmpeg installation | `{:ok, version}` or `{:error, reason}` |
| `extract_video_blobs/2` | Extract blobs to temp files | `{:ok, file_paths}` or `{:error, reason}` |
| `generate_concat_file/2` | Create FFmpeg concat manifest | `{:ok, concat_path}` or `{:error, reason}` |
| `stitch_videos/2` | Execute FFmpeg stitching | `{:ok, output_path}` or `{:error, reason}` |
| `read_video_file/1` | Read video into binary | `{:ok, binary}` or `{:error, reason}` |
| `cleanup_temp_files/1` | Remove temp directory | `:ok` |

### StitchWorker Functions

| Function | Purpose | Returns |
|----------|---------|---------|
| `stitch_job/1` | Stitch all sub_jobs for a job | `{:ok, result}` or `{:error, reason}` |
| `partial_stitch/2` | Stitch only completed sub_jobs | `{:ok, result}` or `{:error, reason}` |

## Configuration

Currently no configuration needed. Defaults:

- Temp directory: `/tmp/job_<id>/`
- Min free space: 100 MB
- FFmpeg command: `ffmpeg -f concat -safe 0 -i concat.txt -c copy -y output.mp4`

## See Also

- Full documentation: `lib/backend/workflow/STITCHING.md`
- Implementation summary: `TASK_9_IMPLEMENTATION.md`
- FFmpeg docs: https://ffmpeg.org/ffmpeg-formats.html#concat
