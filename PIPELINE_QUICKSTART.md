# 🚀 LLM Pipeline System - Quick Start

## TL;DR

```bash
cd backend
mix deps.get
mix ecto.migrate
mix run priv/repo/seeds_pipeline_examples.exs
mix phx.server
```

## Test It

```bash
# Get your API key from existing system
export API_KEY="your-key-here"

# List example pipelines
curl http://localhost:4000/api/v3/pipelines \
  -H "Authorization: Bearer $API_KEY"

# Execute the simple greeting pipeline
curl -X POST http://localhost:4000/api/v3/pipelines/PIPELINE_ID/execute \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "input_data": {
      "name": "World",
      "project": "Ash"
    }
  }'

# Check the run status
curl http://localhost:4000/api/v3/pipeline_runs/RUN_ID \
  -H "Authorization: Bearer $API_KEY"
```

## What You Get

✅ **Full LLM Pipeline System** with Ash Framework
✅ **3 Node Types**: Text, HTTP, LLM
✅ **Background Jobs** via Oban
✅ **RESTful JSON API** auto-generated
✅ **4 Example Pipelines** ready to test

## Node Types

### Text Node
```json
{
  "type": "text",
  "config": {
    "content": "Hello {{name}}!"
  }
}
```

### HTTP Node
```json
{
  "type": "http_request",
  "config": {
    "url": "https://api.example.com/{{endpoint}}",
    "method": "GET"
  }
}
```

### LLM Node
```json
{
  "type": "llm",
  "config": {
    "provider": "openrouter",
    "model": "anthropic/claude-3-5-sonnet",
    "user_prompt": "{{input}}"
  }
}
```

## Common Commands

```bash
# Install deps
mix deps.get

# Run migrations
mix ecto.migrate

# Load examples
mix run priv/repo/seeds_pipeline_examples.exs

# Start server
mix phx.server

# IEx console
iex -S mix phx.server

# Check Oban jobs
# Visit: http://localhost:4000/dev/dashboard
```

## API Endpoints

```
POST   /api/v3/pipelines                    # Create pipeline
GET    /api/v3/pipelines/:id                # Get pipeline
POST   /api/v3/pipelines/:id/execute        # Execute pipeline

POST   /api/v3/nodes                        # Create node
PATCH  /api/v3/nodes/:id                    # Update node

POST   /api/v3/edges                        # Create edge

GET    /api/v3/pipeline_runs/:id            # Check run status
GET    /api/v3/node_results?filter[...]     # Get results
```

## Need Help?

📖 Full docs: `PIPELINE_SETUP.md`
🏗️ Architecture: `ASH_PIPELINE_PLAN.md`

---

**Built with:** Ash Framework 3.4 • Oban 2.18 • Phoenix 1.8 • Elixir 1.15
