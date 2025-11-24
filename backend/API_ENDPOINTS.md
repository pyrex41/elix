# Video Generation API Endpoints

Base URL: `http://localhost:4000/api/v3`

## 🔷 Implemented & Working

### Assets
- `POST /assets/unified` - Upload asset via file or URL
  - Body: `{file: binary}` OR `{source_url: string}`
- `GET /assets/:id/data` - Get asset binary data

### Jobs - Basic Operations
- `GET /jobs/:id` - Get job status and details
  - Payload now includes `video_name`, `estimated_cost`, and a `costs` summary so the UI can display pricing before approvals
- `POST /jobs/:id/approve` - Approve a pending job
- `GET /generated-videos` - List completed videos (query with `job_id`, `campaign_id`, and/or `client_id`)

### Jobs - Creation
- `POST /jobs/from-image-pairs` - Create job from before/after image pairs
  - Body: `{image_pairs: [{before_asset_id, after_asset_id, caption}], style, music_genre}`
  - Response includes `video_name`, the USD `estimated_cost`, and a `costs` summary based on the selected render model
- `POST /jobs/from-property-photos` - Create job from property photos
  - Body: `{asset_ids: [id], property_details: {address, price, ...}, style, music_genre}`
  - Response includes `video_name`, the USD `estimated_cost`, and a `costs` summary based on the selected render model

### Scenes
- `GET /jobs/:job_id/scenes` - List all scenes for a job
- `GET /jobs/:job_id/scenes/:scene_id` - Get scene details
- `PUT /jobs/:job_id/scenes/:scene_id` - Update a scene
- `POST /jobs/:job_id/scenes/:scene_id/regenerate` - Regenerate a scene
- `DELETE /jobs/:job_id/scenes/:scene_id` - Delete a scene

### Videos
- `GET /videos/:job_id/combined` - Get final stitched video (supports Range requests)
- `GET /videos/:job_id/thumbnail` - Get video thumbnail
- `GET /videos/:job_id/clips/:filename` - Get individual clip
- `GET /videos/:job_id/clips/:filename/thumbnail` - Get clip thumbnail

### Audio
- `POST /audio/generate-scenes` - Generate audio for scenes
- `GET /audio/status/:job_id` - Get audio generation status
- `GET /audio/:job_id/download` - Download generated audio

## 🔶 Need to Implement

### Campaigns ⚠️
- `GET /campaigns` - List all campaigns
  - Query: `?client_id=X&status=Y`
- `GET /campaigns/:id` - Get campaign details
- `POST /campaigns` - Create campaign
  - Body: `{name, client_id, status, metadata}`
- `PUT /campaigns/:id` - Update campaign
- `DELETE /campaigns/:id` - Delete campaign
- `GET /campaigns/:id/assets` - Get all campaign assets
- **`POST /campaigns/:id/create-job`** - Create job from campaign (FULL PIPELINE) ⚠️
  - Body: `{style, music_genre, duration_seconds}`
  - This should:
    1. Fetch all campaign assets
    2. Select/organize assets
    3. Generate scenes/storyboard
    4. Create job
    5. Start processing pipeline

### Clients ⚠️
- `GET /clients` - List all clients
- `GET /clients/:id` - Get client details
- `POST /clients` - Create client
  - Body: `{name, email, metadata}`
- `PUT /clients/:id` - Update client
- `DELETE /clients/:id` - Delete client
- `GET /clients/:id/campaigns` - Get all client campaigns

### Users (if needed)
- `GET /users` - List users
- `GET /users/:id` - Get user details
- `POST /users` - Create user
- `PUT /users/:id` - Update user
- `DELETE /users/:id` - Delete user

## 📊 Database Schema

```
Users
  ├─ has_many → Clients

Clients
  ├─ has_many → Campaigns

Campaigns
  ├─ belongs_to → Client
  ├─ has_many → Assets
  ├─ has_many → Jobs

Assets
  ├─ belongs_to → Campaign (optional)

Jobs
  ├─ belongs_to → Campaign (optional)
  ├─ has_many → SubJobs
  ├─ has_many → Scenes (virtual)
```

## 🚀 Quick Test Commands

```bash
# Upload an asset
curl -X POST http://localhost:4000/api/v3/assets/unified \
  -F "file=@image.jpg"

# Create job from campaign (once implemented)
curl -X POST http://localhost:4000/api/v3/campaigns/1/create-job \
  -H "Content-Type: application/json" \
  -d '{"style": "modern", "music_genre": "upbeat"}'

# Get job status
curl http://localhost:4000/api/v3/jobs/1

# Approve job
curl -X POST http://localhost:4000/api/v3/jobs/1/approve

# Get final video
curl http://localhost:4000/api/v3/videos/1/combined --output video.mp4
```

## Alternative Documentation Options

Instead of OpenApiSpex/Swagger, consider:

1. **Phoenix Swagger** - More automatic, uses DSL comments
2. **API Blueprint** - Markdown-based API documentation
3. **Custom JSON endpoint** - Simple endpoint that returns all routes
4. **GraphQL** - If you want a more modern API approach
5. **LiveView Dashboard** - Interactive API explorer using Phoenix LiveView

## Next Steps

1. Implement Campaign endpoints ✅ (just created controller)
2. Implement Client endpoints
3. Implement campaign-based job creation (full pipeline)
4. Either:
   - Finish OpenApiSpex annotations (tedious)
   - Switch to a simpler documentation approach
   - Create a custom route listing endpoint
