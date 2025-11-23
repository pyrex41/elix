# Ash Framework + LLM Pipeline Implementation Plan

## Overview
This document outlines the plan to integrate Ash Framework into the existing Phoenix/Ecto codebase and build a node-based LLM pipeline system inspired by Flowise/Langflow.

## Goals
1. Introduce Ash Framework incrementally without breaking existing functionality
2. Build a flexible, node-based pipeline system for LLM workflows
3. Use Oban for background job orchestration
4. Create a foundation for visual pipeline building (UI can come later)

---

## Phase 1: Ash Framework Setup (Foundation)

### 1.1 Add Dependencies
```elixir
# mix.exs additions
{:ash, "~> 3.4"},
{:ash_phoenix, "~> 2.1"},
{:ash_json_api, "~> 1.4"},
{:ash_sqlite, "~> 0.1"},  # SQLite support for Ash
{:oban, "~> 2.18"},       # Background jobs
{:liquid, "~> 0.11"},     # Templating for node variables
```

### 1.2 Create Ash Domain Structure
```
lib/backend/
├── pipelines/           # New Ash domain
│   ├── domain.ex       # Ash.Domain definition
│   ├── resources/      # Ash resources
│   │   ├── pipeline.ex
│   │   ├── node.ex
│   │   ├── edge.ex
│   │   ├── pipeline_run.ex
│   │   └── node_result.ex
│   ├── actions/        # Custom actions
│   │   └── execute_pipeline.ex
│   ├── calculations/   # Derived fields
│   ├── changes/        # Change modules
│   └── node_types/     # Node implementations
│       ├── text_node.ex
│       ├── http_node.ex
│       └── llm_node.ex
```

### 1.3 Configuration
```elixir
# config/config.exs
config :backend, :ash_domains, [Backend.Pipelines.Domain]

config :backend, Oban,
  repo: Backend.Repo,
  queues: [default: 10, pipelines: 5, nodes: 20]
```

---

## Phase 2: Core Pipeline Resources (Ash Resources)

### 2.1 Resource: Pipeline
**Purpose:** Container for a collection of connected nodes

**Attributes:**
- `id` (UUID, primary key)
- `name` (string, required)
- `description` (text)
- `status` (enum: draft, active, archived)
- `metadata` (map) - arbitrary JSON data
- `inserted_at`, `updated_at` (timestamps)

**Relationships:**
- `has_many :nodes` - All nodes in this pipeline
- `has_many :edges` - All connections between nodes
- `has_many :runs` - Historical executions

**Actions:**
- `create` - Create new pipeline
- `update` - Modify pipeline structure
- `archive` - Soft delete
- `execute` - Trigger a new pipeline run (spawns Oban job)

**State Machine:**
- States: draft → active → archived
- Transitions: publish, archive, reactivate

---

### 2.2 Resource: Node
**Purpose:** Individual step in the pipeline

**Attributes:**
- `id` (UUID, primary key)
- `pipeline_id` (UUID, foreign key)
- `type` (enum: text, http_request, llm, condition, transform)
- `name` (string)
- `config` (map) - Node-specific configuration (JSON)
  - For LLM: `{model, system_prompt, temperature, max_tokens}`
  - For HTTP: `{url, method, headers, body_template}`
  - For Text: `{content_template}`
- `position` (map) - UI coordinates `{x, y}`
- `metadata` (map)

**Relationships:**
- `belongs_to :pipeline`
- `has_many :outgoing_edges` (source node)
- `has_many :incoming_edges` (target node)

**Actions:**
- `create`, `update`, `delete`
- `validate_config` - Type-specific validation
- `execute` - Run this node's logic (polymorphic by type)

**Calculations:**
- `can_execute?` - Check if dependencies are met
- `dependency_count` - Number of incoming edges

---

### 2.3 Resource: Edge
**Purpose:** Connection between two nodes (data flow)

**Attributes:**
- `id` (UUID, primary key)
- `pipeline_id` (UUID, foreign key)
- `source_node_id` (UUID, foreign key)
- `target_node_id` (UUID, foreign key)
- `source_handle` (string, nullable) - For multi-output nodes
- `target_handle` (string, nullable) - For multi-input nodes
- `metadata` (map)

**Relationships:**
- `belongs_to :pipeline`
- `belongs_to :source_node`
- `belongs_to :target_node`

**Validations:**
- No cycles in the graph
- Source and target must be in the same pipeline
- No duplicate edges between same nodes

**Actions:**
- `create`, `delete`
- `validate_no_cycles` - Prevent circular dependencies

---

### 2.4 Resource: PipelineRun
**Purpose:** Single execution of a pipeline

**Attributes:**
- `id` (UUID, primary key)
- `pipeline_id` (UUID, foreign key)
- `status` (enum: pending, running, completed, failed, cancelled)
- `started_at` (utc_datetime)
- `completed_at` (utc_datetime)
- `error_message` (text, nullable)
- `input_data` (map) - Initial inputs for the pipeline
- `output_data` (map) - Final outputs
- `metadata` (map)

**Relationships:**
- `belongs_to :pipeline`
- `has_many :node_results` - Results for each node execution

**State Machine (AshStateMachine):**
- States: pending → running → (completed | failed | cancelled)
- Transitions:
  - `start` (pending → running)
  - `complete` (running → completed)
  - `fail` (running → failed)
  - `cancel` (* → cancelled)

**Actions:**
- `create` - Start new run
- `start` - Transition to running (spawns Oban coordinator job)
- `complete` - Mark as completed
- `fail` - Mark as failed with error
- `cancel` - User-initiated cancellation

**Calculations:**
- `duration` - completed_at - started_at
- `progress_percent` - (completed_nodes / total_nodes) * 100

---

### 2.5 Resource: NodeResult
**Purpose:** Output of a single node execution within a run

**Attributes:**
- `id` (UUID, primary key)
- `pipeline_run_id` (UUID, foreign key)
- `node_id` (UUID, foreign key)
- `status` (enum: pending, running, completed, failed, skipped)
- `started_at` (utc_datetime)
- `completed_at` (utc_datetime)
- `input_data` (map) - Data passed to this node
- `output_data` (map) - Data produced by this node
- `error_message` (text, nullable)
- `metadata` (map) - Execution metadata (tokens used, duration, etc.)

**Relationships:**
- `belongs_to :pipeline_run`
- `belongs_to :node`

**Actions:**
- `create` - Initialize result
- `start` - Mark as running (spawns Oban node execution job)
- `complete` - Store output
- `fail` - Store error

**Calculations:**
- `duration` - completed_at - started_at
- `retry_count` - Count of retry attempts

---

## Phase 3: Node Type Implementations

### 3.1 Node Executor Protocol
```elixir
defprotocol Backend.Pipelines.NodeExecutor do
  @doc "Execute the node logic with the given inputs"
  def execute(node, inputs, context)

  @doc "Validate the node configuration"
  def validate_config(node)
end
```

### 3.2 Text Node
**Purpose:** Output static or templated text

**Config:**
```json
{
  "content": "Hello {{name}}, your order {{order_id}} is ready!"
}
```

**Execution:**
1. Receive input variables from previous nodes
2. Render Liquid template with input data
3. Return rendered text as output

### 3.3 HTTP Request Node
**Purpose:** Make HTTP requests to external APIs

**Config:**
```json
{
  "url": "https://api.example.com/{{endpoint}}",
  "method": "POST",
  "headers": {
    "Authorization": "Bearer {{api_key}}",
    "Content-Type": "application/json"
  },
  "body": "{\"data\": \"{{input_data}}\"}"
}
```

**Execution:**
1. Render URL and body templates with inputs
2. Make HTTP request using Req
3. Return response body as output
4. Handle errors (retry logic via Oban)

### 3.4 LLM Node (OpenRouter)
**Purpose:** Call LLM APIs

**Config:**
```json
{
  "provider": "openrouter",
  "model": "anthropic/claude-3-5-sonnet",
  "system_prompt": "You are a helpful assistant",
  "user_prompt": "{{user_input}}",
  "temperature": 0.7,
  "max_tokens": 1000
}
```

**Execution:**
1. Render prompts with input data
2. Call LLM API (OpenRouter, xAI, etc.)
3. Return response text and metadata
4. Track token usage in metadata

### 3.5 Future Node Types
- **Condition Node:** Branch execution based on logic
- **Transform Node:** JSONPath transformations
- **Image Node:** Handle image inputs
- **Loop Node:** Iterate over arrays
- **Agent Node:** Recursive pipeline calls

---

## Phase 4: Execution Engine (Oban Jobs)

### 4.1 Job: PipelineCoordinator
**Purpose:** Orchestrate pipeline execution

**Logic:**
1. Load PipelineRun and all nodes/edges
2. Build dependency graph (topological sort)
3. Find all nodes ready to execute (no pending dependencies)
4. Enqueue NodeExecutor jobs for ready nodes (parallel execution)
5. Wait for node completions
6. Repeat until all nodes complete or error
7. Update PipelineRun status

**Oban Configuration:**
- Queue: `pipelines`
- Max attempts: 3
- Priority: high

### 4.2 Job: NodeExecutor
**Purpose:** Execute a single node

**Logic:**
1. Load Node and NodeResult
2. Gather input data from previous NodeResults
3. Resolve node type and call appropriate executor
4. Render templates using Liquid
5. Execute node logic (HTTP, LLM, etc.)
6. Store output in NodeResult
7. Notify PipelineCoordinator to check for next nodes

**Oban Configuration:**
- Queue: `nodes`
- Max attempts: 5 (with exponential backoff)
- Priority: normal

### 4.3 Concurrency & Dependencies
- Nodes with no dependencies start immediately
- Nodes wait for ALL incoming edges to complete
- Parallel execution when possible (fan-out)
- Fan-in merging of multiple outputs

---

## Phase 5: API Integration (AshJsonApi)

### 5.1 Endpoints
```
POST   /api/v3/pipelines                 - Create pipeline
GET    /api/v3/pipelines/:id             - Get pipeline
PATCH  /api/v3/pipelines/:id             - Update pipeline
DELETE /api/v3/pipelines/:id             - Delete pipeline
POST   /api/v3/pipelines/:id/execute     - Execute pipeline

POST   /api/v3/pipelines/:id/nodes       - Create node
PATCH  /api/v3/pipelines/:id/nodes/:id   - Update node
DELETE /api/v3/pipelines/:id/nodes/:id   - Delete node

POST   /api/v3/pipelines/:id/edges       - Create edge
DELETE /api/v3/pipelines/:id/edges/:id   - Delete edge

GET    /api/v3/pipeline_runs/:id         - Get run status
GET    /api/v3/pipeline_runs/:id/results - Get all node results
POST   /api/v3/pipeline_runs/:id/cancel  - Cancel run
```

### 5.2 AshJsonApi Configuration
```elixir
# lib/backend/pipelines/domain.ex
use Ash.Domain,
  extensions: [AshJsonApi.Domain]

json_api do
  prefix "/api/v3"

  routes do
    base_route "/pipelines", Backend.Pipelines.Pipeline do
      get :read
      index :list
      post :create
      patch :update
      delete :destroy

      post :execute, route: "/:id/execute"
    end

    # ... similar for other resources
  end
end
```

---

## Phase 6: Integration with Existing System

### 6.1 Coexistence Strategy
- Keep existing controllers/services untouched
- Run Ash APIs alongside existing v3 API
- Gradual migration: new features use Ash, existing use Ecto
- Share same Repo and database

### 6.2 Shared Infrastructure
- Same SQLite database
- Same API authentication (ApiKeyAuth plug)
- Same error handling patterns
- Reuse existing services (AiService, ReplicateService)

### 6.3 Leverage Existing Services
**Wrap existing services in Ash changes/actions:**
```elixir
# lib/backend/pipelines/changes/call_ai_service.ex
defmodule Backend.Pipelines.Changes.CallAiService do
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    # Call existing Backend.Services.AiService
    # This preserves existing business logic
  end
end
```

---

## Phase 7: Data Migrations

### 7.1 New Tables
```sql
CREATE TABLE pipelines (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL,
  metadata TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE nodes (
  id TEXT PRIMARY KEY,
  pipeline_id TEXT NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  name TEXT NOT NULL,
  config TEXT NOT NULL,
  position TEXT,
  metadata TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE edges (
  id TEXT PRIMARY KEY,
  pipeline_id TEXT NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE,
  source_node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  target_node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  source_handle TEXT,
  target_handle TEXT,
  metadata TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(source_node_id, target_node_id, source_handle, target_handle)
);

CREATE TABLE pipeline_runs (
  id TEXT PRIMARY KEY,
  pipeline_id TEXT NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  error_message TEXT,
  input_data TEXT,
  output_data TEXT,
  metadata TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE node_results (
  id TEXT PRIMARY KEY,
  pipeline_run_id TEXT NOT NULL REFERENCES pipeline_runs(id) ON DELETE CASCADE,
  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  input_data TEXT,
  output_data TEXT,
  error_message TEXT,
  metadata TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_nodes_pipeline ON nodes(pipeline_id);
CREATE INDEX idx_edges_pipeline ON edges(pipeline_id);
CREATE INDEX idx_edges_source ON edges(source_node_id);
CREATE INDEX idx_edges_target ON edges(target_node_id);
CREATE INDEX idx_runs_pipeline ON pipeline_runs(pipeline_id);
CREATE INDEX idx_results_run ON node_results(pipeline_run_id);
CREATE INDEX idx_results_node ON node_results(node_id);
```

---

## Phase 8: Testing Strategy

### 8.1 Unit Tests
- Test each node type executor
- Test template rendering with Liquid
- Test graph validation (cycle detection)
- Test state machine transitions

### 8.2 Integration Tests
- Test pipeline creation via API
- Test pipeline execution end-to-end
- Test error handling and retries
- Test concurrent node execution

### 8.3 Example Pipeline
**"Image Description Pipeline":**
```
[Text Node: "Describe this image"]
    ↓
[HTTP Node: Fetch image from URL]
    ↓
[LLM Node: Vision model with image + prompt]
    ↓
[Text Node: Format output]
```

---

## Implementation Timeline

### Sprint 1 (Weeks 1-2): Foundation
- [ ] Add Ash, Oban, Liquid dependencies
- [ ] Set up Ash domain structure
- [ ] Create basic Pipeline and Node resources
- [ ] Write migrations

### Sprint 2 (Weeks 3-4): Core Resources
- [ ] Complete all 5 Ash resources
- [ ] Implement state machines
- [ ] Add validations and calculations
- [ ] Set up AshJsonApi routes

### Sprint 3 (Weeks 5-6): Node Types
- [ ] Implement NodeExecutor protocol
- [ ] Build Text, HTTP, LLM node executors
- [ ] Add Liquid template rendering
- [ ] Test node execution

### Sprint 4 (Weeks 7-8): Execution Engine
- [ ] Build PipelineCoordinator Oban job
- [ ] Build NodeExecutor Oban job
- [ ] Implement dependency resolution
- [ ] Add concurrency handling

### Sprint 5 (Weeks 9-10): Integration & Testing
- [ ] Integrate with existing API
- [ ] Write comprehensive tests
- [ ] Build example pipelines
- [ ] Documentation

### Sprint 6 (Week 11+): Polish & Extensions
- [ ] Add more node types
- [ ] Improve error handling
- [ ] Performance optimization
- [ ] Monitoring and observability

---

## Future Enhancements

### UI (Post-MVP)
- Phoenix LiveView + SvelteFlow integration
- Drag-and-drop pipeline builder
- Real-time execution visualization
- Node configuration forms

### Advanced Features
- Conditional branching nodes
- Loop/iteration nodes
- Sub-pipeline/recursive calls
- Webhooks as triggers
- Scheduled pipeline execution
- Pipeline versioning
- A/B testing pipelines

### Integrations
- Direct integrations with common APIs (Stripe, Slack, etc.)
- OpenAI function calling / agents
- Vector database nodes (embeddings, search)
- File upload/download nodes

---

## Questions to Resolve

1. **LLM Provider:** Use OpenRouter, or stick with existing xAI integration?
2. **UI Timeline:** Build API first, UI later? Or parallel development?
3. **Authentication:** Same API key auth, or pipeline-specific access control?
4. **Rate Limiting:** How to handle LLM API rate limits in pipelines?
5. **Cost Tracking:** Track token usage and costs per pipeline run?
6. **Caching:** Cache node results to avoid re-execution?

---

## Success Metrics

- [ ] Create a pipeline via API
- [ ] Execute pipeline with 3+ nodes
- [ ] LLM node successfully calls OpenRouter/xAI
- [ ] Parallel node execution works
- [ ] Error handling gracefully fails and retries
- [ ] Pipeline runs complete in < 30 seconds (for simple pipelines)
- [ ] Can visualize execution results

---

## Resources & References

- [Ash Framework Docs](https://hexdocs.pm/ash)
- [Ash Getting Started](https://hexdocs.pm/ash/get-started.html)
- [AshJsonApi](https://hexdocs.pm/ash_json_api)
- [AshStateMachine](https://hexdocs.pm/ash_state_machine)
- [Oban Documentation](https://hexdocs.pm/oban)
- [Liquid Templating](https://github.com/bettyblocks/liquid-elixir)
- [Will Townsend's Blog Post](https://willtownsend.co/2025/llm-pipelines-elixir-ash)

---

**Let's build this! 🚀**
