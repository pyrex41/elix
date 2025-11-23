# 🎬 AI Video Pipeline Testing Guide for Prompt Development Team

## Quick Start

### 1. Access the Testing UI

Navigate to: **`https://your-api-url/api/v3/testing/ui`**

On first visit, you'll be prompted to enter your API key. This will be saved in your browser for future sessions.

---

## 🎯 What's Available

This PR adds a comprehensive testing infrastructure for developing and refining prompts for our AI video generation pipeline. You can now:

- ✅ **Test scene templates** - View and adapt all 7 scene types
- ✅ **Test image selection** - See which images the LLM selects for each scene
- ✅ **Test music generation** - Generate and preview music for scenes
- ✅ **Test text overlays** - Preview and apply text overlays with different styles
- ✅ **Test voiceover scripts** - Generate scripts from property details
- ✅ **Control pipeline steps** - Enable/disable features like overlays and voiceovers
- ✅ **Browse resources** - View campaigns, assets, and jobs

---

## 📋 Testing Workflows

### Testing Scene Templates & Video Prompts

**Goal**: Verify that the 7 scene templates have the right prompts for video generation

1. Click **"Load Templates"** in the Scene Templates section
2. Review the JSON output for each scene type:
   - `hook` - Exterior feature (pool, courtyard)
   - `bedroom` - Hero bedroom with parallax
   - `vanity` - Bathroom vanity with symmetry
   - `tub` - Feature tub/shower with depth
   - `living_room` - Living room sweep
   - `dining` - Dining/lifestyle area
   - `outro` - Establishing wide shot

3. Check the `video_prompt` field for each scene - these are what get sent to the video generation model
4. Verify `motion_goal` and `camera_movement` match your creative vision

**Testing Prompt Variations**:
```bash
# API endpoint for testing prompt previews
POST /api/v3/testing/prompt-preview
{
  "scene_type": "hook",
  "for": "video"  # or "music"
}
```

---

### Testing Image Selection (LLM-Based)

**Goal**: Verify the LLM is selecting the best image pairs for each scene type

1. Get a campaign ID by clicking **"Load Campaigns"** in section 6
2. Enter the campaign ID in section 2
3. Set scene count (default: 7)
4. Click **"Test Selection"**

**What to look for**:
- `selected_assets` - Check if the LLM picked appropriate images for each scene type
- `selection_reasoning` - Read why the LLM chose those images
- Verify `first_image_id` and `last_image_id` make sense for smooth transitions

**Example Response**:
```json
{
  "scenes": [
    {
      "title": "The Hook",
      "scene_type": "hook",
      "asset_ids": ["uuid-1", "uuid-2"],
      "selected_assets": [
        {
          "id": "uuid-1",
          "metadata": {"original_name": "Pool Exterior"},
          "asset_url": "/api/v3/assets/uuid-1/data"
        }
      ],
      "selection_reasoning": "These images showcase the pool with great lighting..."
    }
  ]
}
```

---

### Testing Music Generation

**Goal**: Test music prompts and ensure they match scene energy/style

#### Single Scene Music Test:
```bash
POST /api/v3/testing/music/single-scene
{
  "scene": {
    "title": "The Hook",
    "duration": 4,
    "music_description": "Opening cinematic impact with subtle water ambience",
    "music_style": "cinematic, ambient, uplifting",
    "music_energy": "medium-high"
  }
}
```

#### Multi-Scene with Continuation:
1. In section 3, enter scene types: `hook,bedroom,vanity,tub,living_room,dining,outro`
2. Click **"Generate Music"**
3. This will generate 4-second segments for each scene with continuation tokens for seamless transitions

**What to verify**:
- Total audio size matches expected duration (7 scenes × 4 seconds = ~28 seconds)
- Each scene uses the correct `music_style` and `music_energy` from templates
- No gaps between scenes (continuation working correctly)

---

### Testing Text Overlays

**Goal**: Test different text overlay styles and positions

#### Preview Overlay Settings (No Video Required):
```bash
POST /api/v3/testing/overlay/preview
{
  "text": "Luxury Mountain Retreat",
  "options": {
    "font_size": 48,
    "color": "white",
    "position": "bottom_center",  # or "top_left", "center", etc.
    "fade_in": 0.5,
    "fade_out": 0.5
  }
}
```

#### Apply to Actual Video:
```bash
POST /api/v3/testing/overlay/text
{
  "job_id": 123,  # Use a completed job with video
  "text": "Mountain Vista Estate",
  "options": {
    "font_size": 60,
    "position": "bottom_center",
    "color": "white",
    "fade_in": 0.5,
    "fade_out": 0.5
  }
}
```

**Position Options**:
- `top_left`, `top_center`, `top_right`
- `center`
- `bottom_left`, `bottom_center`, `bottom_right`
- Custom: `"x=100:y=200"`

---

### Testing Voiceover Scripts

**Goal**: Generate and refine voiceover scripts for properties

1. Enter a property name in section 5
2. Click **"Generate Script"**

This will use Grok to generate a script based on:
- Property details (name, type, features, location)
- Scene descriptions
- Desired tone (professional, engaging, luxury)

**Example API Call**:
```bash
POST /api/v3/testing/voiceover/script
{
  "property_details": {
    "name": "Mountain Vista Estate",
    "type": "luxury mountain retreat",
    "features": ["infinity pool", "mountain views", "spa", "chef's kitchen"],
    "location": "Aspen, Colorado"
  },
  "scenes": [
    {"title": "Exterior", "description": "Pool area with mountain backdrop"},
    {"title": "Master Bedroom", "description": "Floor-to-ceiling windows"}
  ],
  "options": {
    "tone": "professional and engaging",
    "style": "luxury real estate"
  }
}
```

**Response**:
```json
{
  "full_script": "Complete paragraph script...",
  "segments": [
    {"scene": 1, "script": "Welcome to Mountain Vista Estate..."},
    {"scene": 2, "script": "Step inside the master suite..."}
  ]
}
```

---

## 🎛️ Pipeline Configuration

### Enabling/Disabling Pipeline Steps

The pipeline config section lets you control which features are active:

**Default Configuration**:
- ✅ Scene generation - **enabled**
- ✅ Image selection - **enabled**
- ✅ Video rendering - **enabled**
- ⭕ Text overlays - **disabled** (toggle on to test)
- ⭕ Voiceovers - **disabled** (toggle on to test)
- ⭕ Avatar overlays - **disabled** (future feature)
- ✅ Music generation - **enabled**
- ✅ Video stitching - **enabled**

**To Enable Text Overlays**:
1. Click **"Load Config"** in the Pipeline Configuration section
2. Toggle the switch next to **text_overlays**
3. This will update the runtime configuration

**Via API**:
```bash
POST /api/v3/testing/pipeline/config
{
  "step": "text_overlays",
  "updates": {
    "enabled": true,
    "default_font_size": 60,
    "default_color": "white"
  }
}
```

---

## 📊 Viewing Campaign Resources

### Browse Campaigns:
1. Click **"Load Campaigns"** in section 6
2. View all available campaigns with image counts

### View Campaign Assets:
```bash
GET /api/v3/testing/campaigns/:id/assets
```

Returns all images with:
- Asset IDs
- Metadata (scene types, tags)
- Direct URLs to view images

### View Job Details:
```bash
GET /api/v3/testing/jobs/:id/preview
```

Shows:
- All scenes in the job
- Selected assets for each scene
- Asset URLs for viewing
- Current job status

---

## 💡 Common Testing Scenarios

### Scenario 1: Testing New Video Prompt Variations

**Goal**: You want to test different prompt styles for the "Hook" scene

1. **View Current Template**:
   - Load templates, find `hook` scene
   - Note current `video_prompt`

2. **Test with Real Campaign**:
   - Load campaigns, pick one with good pool/exterior photos
   - Run image selection test
   - Check which images were selected for the hook scene

3. **Modify Template** (in code):
   - Edit `backend/lib/backend/templates/scene_templates.ex`
   - Update the `video_prompt` for `:hook`
   - Restart server

4. **Re-test**:
   - Run image selection again
   - Compare results

---

### Scenario 2: Testing Music Prompt Variations

**Goal**: Adjust music style/energy for bedroom scenes

1. **Generate Music** with current template:
   ```bash
   POST /api/v3/testing/music/from-templates
   {
     "scene_types": ["bedroom"],
     "default_duration": 4.0
   }
   ```

2. **Review Output**:
   - Check generated prompt used
   - Listen to music (if you have Replicate API key)

3. **Adjust Template**:
   - Modify `music_style` or `music_energy` for `:bedroom` in scene_templates.ex
   - Options: "elegant, serene, sophisticated" vs "romantic, intimate, soft"

4. **Re-test** and compare

---

### Scenario 3: Testing Complete Pipeline

**Goal**: Run a full property through the pipeline with all features enabled

1. **Enable All Features**:
   - Toggle on text_overlays
   - Toggle on voiceover
   - Keep music_generation enabled

2. **Generate Script**:
   ```bash
   POST /api/v3/testing/voiceover/script
   {
     "property_details": {...},
     "scenes": [...]
   }
   ```

3. **Test Image Selection**:
   ```bash
   POST /api/v3/testing/image-selection
   {
     "campaign_id": 123,
     "scene_count": 7
   }
   ```

4. **Generate Music**:
   ```bash
   POST /api/v3/testing/music/from-templates
   {
     "scene_types": ["hook", "bedroom", "vanity", "tub", "living_room", "dining", "outro"]
   }
   ```

5. **Test Text Overlay** (after video is rendered):
   ```bash
   POST /api/v3/testing/overlay/text
   {
     "job_id": completed_job_id,
     "text": "Property Name"
   }
   ```

---

## 🔧 Advanced: Using cURL for Testing

If you prefer command-line testing:

```bash
# Set your API key
API_KEY="your-api-key-here"
BASE_URL="https://your-api-url/api/v3/testing"

# Test image selection
curl -X POST "$BASE_URL/image-selection" \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "campaign_id": 123,
    "scene_count": 7,
    "brief": "Luxury mountain retreat with modern design"
  }'

# Preview text overlay
curl -X POST "$BASE_URL/overlay/preview" \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Mountain Vista Estate",
    "options": {
      "font_size": 48,
      "position": "bottom_center",
      "color": "white"
    }
  }'

# Generate voiceover script
curl -X POST "$BASE_URL/voiceover/script" \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "property_details": {
      "name": "Mountain Vista Estate",
      "type": "luxury mountain retreat",
      "features": ["infinity pool", "mountain views", "spa"],
      "location": "Aspen, Colorado"
    },
    "scenes": [
      {"title": "Exterior", "description": "Pool area"},
      {"title": "Bedroom", "description": "Master suite"}
    ]
  }'
```

---

## 📝 Key Files for Prompt Development

When refining prompts, you'll mainly work with:

**Scene Templates** (Video & Music Prompts):
```
backend/lib/backend/templates/scene_templates.ex
```

**TTS Script Generation** (Voiceover Prompts):
```
backend/lib/backend/services/tts_service.ex
# See: build_script_generation_prompt/3
```

**Image Selection** (LLM Selection Prompts):
```
backend/lib/backend/services/ai_service.ex
# See: get_image_pair_selection_system_prompt/0
```

---

## 🚀 Production Deployment Notes

### Disabling Testing Endpoints

In production, you can disable testing endpoints by setting:

```elixir
# config/prod.exs
config :backend,
  enable_testing_endpoints: false
```

This will remove all `/api/v3/testing/*` endpoints from the production API.

### TTS API Keys

Configure TTS providers in your environment:

```elixir
config :backend,
  elevenlabs_api_key: System.get_env("ELEVENLABS_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  xai_api_key: System.get_env("XAI_API_KEY")
```

---

## 💬 Questions or Issues?

If you encounter any issues or need additional testing features:
1. Check the logs for detailed error messages
2. Verify your API key has proper permissions
3. Ensure all required API keys are configured (xAI for LLM, Replicate for music/video)
4. Open an issue on GitHub with the error details

---

## 🎯 Summary

This testing infrastructure gives you:
- **Real-time prompt testing** without running full jobs
- **LLM selection visibility** to see what images are being chosen
- **Music generation testing** for different scene styles
- **Text overlay experimentation** with various positions/styles
- **Script generation** powered by Grok for voiceovers
- **Pipeline control** to enable/disable features as needed

Happy testing! 🎬✨
