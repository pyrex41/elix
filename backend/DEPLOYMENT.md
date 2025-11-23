# Fly.io Deployment Guide

## Prerequisites

1. Install flyctl: `brew install flyctl` (Mac) or see https://fly.io/docs/hands-on/install-flyctl/
2. Login to fly.io: `flyctl auth login`
3. Have your API keys ready:
   - Replicate API key (https://replicate.com/account/api-tokens)
   - XAI API key (https://x.ai/api)

## Initial Setup

### 1. Create the app (first time only)
```bash
cd backend
flyctl launch --no-deploy
```

This will use the existing `fly.toml` configuration.

### 2. Create persistent storage volume
```bash
flyctl volumes create physics_data --region dfw --size 10
```

### 3. Set secrets
```bash
# Generate a secret key base
mix phx.gen.secret

# Set all required secrets
flyctl secrets set \
  SECRET_KEY_BASE=<your_generated_secret> \
  REPLICATE_API_KEY=<your_replicate_api_key> \
  XAI_API_KEY=<your_xai_api_key> \
  PUBLIC_BASE_URL=https://gauntlet-video-server.fly.dev \
  VIDEO_GENERATION_MODEL=veo3
```

## Deploy

```bash
# Deploy the application
flyctl deploy

# Check status
flyctl status

# View logs
flyctl logs

# Open in browser
flyctl open
```

## Post-Deployment

### Test the API
```bash
# Health check
curl https://gauntlet-video-server.fly.dev/api/openapi

# Create a test job
curl -X POST https://gauntlet-video-server.fly.dev/api/v3/jobs/from-image-pairs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-api-key" \
  -d '{
    "campaign_id": "your-campaign-id",
    "num_pairs": 1,
    "clip_duration": 3
  }'
```

### Monitor
```bash
# Real-time logs
flyctl logs -a gauntlet-video-server

# SSH into the machine
flyctl ssh console

# Check database
flyctl ssh console -C "ls -lh /data"
```

## Scaling

### Update machine specs
```bash
# Scale memory
flyctl scale memory 4096

# Scale to multiple machines
flyctl scale count 2
```

### Update configuration
Edit `fly.toml` and redeploy:
```bash
flyctl deploy
```

## Troubleshooting

### Database issues
```bash
# SSH into machine and check database
flyctl ssh console
cd /data
ls -lh backend.db
```

### Application not starting
```bash
# Check logs
flyctl logs

# Restart the app
flyctl apps restart gauntlet-video-server
```

### FFmpeg issues
The Dockerfile includes FFmpeg for video stitching. If you encounter issues:
```bash
# SSH and verify FFmpeg
flyctl ssh console -C "ffmpeg -version"
```

## Environment Variables

Required secrets (set with `flyctl secrets set`):
- `SECRET_KEY_BASE` - Phoenix secret (generate with `mix phx.gen.secret`)
- `REPLICATE_API_KEY` - For video generation
- `XAI_API_KEY` - For AI scene selection
- `PUBLIC_BASE_URL` - Your fly.io app URL (https://gauntlet-video-server.fly.dev)
- `VIDEO_GENERATION_MODEL` - Default: veo3

Set in fly.toml (no secrets needed):
- `PHX_HOST` - gauntlet-video-server.fly.dev
- `PORT` - 8080
- `PHX_SERVER` - true
- `DATABASE_PATH` - /data/backend.db

## Cost Considerations

With current configuration:
- 2GB RAM, 2 shared CPUs
- Auto-suspend when idle (min_machines_running = 0)
- 10GB persistent volume
- Estimated: ~$10-15/month (suspended most of the time)
- Active processing: ~$0.02/hour

## Updates

To deploy code changes:
```bash
git add .
git commit -m "Your changes"
flyctl deploy
```

## Rollback

If something goes wrong:
```bash
flyctl releases
flyctl releases rollback <version>
```
