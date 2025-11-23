# Example Pipeline Seeds
# Run with: mix run priv/repo/seeds_pipeline_examples.exs

alias Backend.Pipelines.Resources.{Pipeline, Node, Edge}

# Example 1: Simple Text Pipeline
# This pipeline just outputs a greeting message

{:ok, text_pipeline} =
  Pipeline.create(%{
    name: "Simple Greeting Pipeline",
    description: "A simple pipeline that outputs a greeting",
    status: :active
  })

{:ok, text_node} =
  Node.create(%{
    pipeline_id: text_pipeline.id,
    name: "Greeting Node",
    type: :text,
    config: %{
      "content" => "Hello {{name}}! Welcome to the {{project}} pipeline system."
    },
    position: %{"x" => 100, "y" => 100}
  })

IO.puts("✅ Created 'Simple Greeting Pipeline' with ID: #{text_pipeline.id}")

# Example 2: HTTP API Pipeline
# This pipeline fetches data from an API

{:ok, http_pipeline} =
  Pipeline.create(%{
    name: "HTTP API Fetch Pipeline",
    description: "Fetches data from a public API",
    status: :active
  })

{:ok, http_node} =
  Node.create(%{
    pipeline_id: http_pipeline.id,
    name: "Fetch User",
    type: :http_request,
    config: %{
      "url" => "https://jsonplaceholder.typicode.com/users/{{user_id}}",
      "method" => "GET",
      "headers" => %{}
    },
    position: %{"x" => 100, "y" => 100}
  })

{:ok, format_node} =
  Node.create(%{
    pipeline_id: http_pipeline.id,
    name: "Format Response",
    type: :text,
    config: %{
      "content" => "User found: {{body.name}} ({{body.email}})"
    },
    position: %{"x" => 300, "y" => 100}
  })

{:ok, _edge1} =
  Edge.create(%{
    pipeline_id: http_pipeline.id,
    source_node_id: http_node.id,
    target_node_id: format_node.id
  })

IO.puts("✅ Created 'HTTP API Fetch Pipeline' with ID: #{http_pipeline.id}")

# Example 3: LLM Pipeline (requires API key)
# This pipeline uses an LLM to generate content

{:ok, llm_pipeline} =
  Pipeline.create(%{
    name: "LLM Content Generation Pipeline",
    description: "Uses an LLM to generate creative content",
    status: :active
  })

{:ok, prompt_node} =
  Node.create(%{
    pipeline_id: llm_pipeline.id,
    name: "Prepare Prompt",
    type: :text,
    config: %{
      "content" => "Write a short {{style}} poem about {{topic}}"
    },
    position: %{"x" => 100, "y" => 100}
  })

{:ok, llm_node} =
  Node.create(%{
    pipeline_id: llm_pipeline.id,
    name: "Generate with LLM",
    type: :llm,
    config: %{
      "provider" => "openrouter",
      "model" => "anthropic/claude-3-5-sonnet",
      "system_prompt" => "You are a creative poet.",
      "user_prompt" => "{{text}}",
      "temperature" => 0.8,
      "max_tokens" => 200
    },
    position: %{"x" => 300, "y" => 100}
  })

{:ok, format_llm_node} =
  Node.create(%{
    pipeline_id: llm_pipeline.id,
    name: "Format Poem",
    type: :text,
    config: %{
      "content" => "Generated Poem:\n\n{{text}}"
    },
    position: %{"x" => 500, "y" => 100}
  })

{:ok, _edge2} =
  Edge.create(%{
    pipeline_id: llm_pipeline.id,
    source_node_id: prompt_node.id,
    target_node_id: llm_node.id
  })

{:ok, _edge3} =
  Edge.create(%{
    pipeline_id: llm_pipeline.id,
    source_node_id: llm_node.id,
    target_node_id: format_llm_node.id
  })

IO.puts("✅ Created 'LLM Content Generation Pipeline' with ID: #{llm_pipeline.id}")

# Example 4: Image Description Pipeline (Advanced)
# This pipeline fetches an image URL and describes it using an LLM

{:ok, image_pipeline} =
  Pipeline.create(%{
    name: "Image Description Pipeline",
    description: "Fetches an image and generates a description",
    status: :active
  })

{:ok, prompt_image_node} =
  Node.create(%{
    pipeline_id: image_pipeline.id,
    name: "Prepare Image Prompt",
    type: :text,
    config: %{
      "content" => "Describe this image in detail: {{image_url}}"
    },
    position: %{"x" => 100, "y" => 100}
  })

{:ok, vision_node} =
  Node.create(%{
    pipeline_id: image_pipeline.id,
    name: "Vision LLM",
    type: :llm,
    config: %{
      "provider" => "openrouter",
      "model" => "anthropic/claude-3-5-sonnet",
      "system_prompt" => "You are an expert at describing images in vivid detail.",
      "user_prompt" => "{{text}}",
      "temperature" => 0.7,
      "max_tokens" => 500
    },
    position: %{"x" => 300, "y" => 100}
  })

{:ok, _edge4} =
  Edge.create(%{
    pipeline_id: image_pipeline.id,
    source_node_id: prompt_image_node.id,
    target_node_id: vision_node.id
  })

IO.puts("✅ Created 'Image Description Pipeline' with ID: #{image_pipeline.id}")

IO.puts("\n🎉 All example pipelines created successfully!")
IO.puts("\nTo execute a pipeline, use:")
IO.puts("  Pipeline.execute(pipeline_id, %{\"name\" => \"World\", \"project\" => \"Ash\"})")
