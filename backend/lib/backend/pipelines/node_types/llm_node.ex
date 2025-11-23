defmodule Backend.Pipelines.NodeTypes.LlmNode do
  @moduledoc """
  LLM Node: Calls large language model APIs (OpenRouter, xAI, etc).

  Configuration:
    {
      "provider": "openrouter",  // or "xai"
      "model": "anthropic/claude-3-5-sonnet",
      "system_prompt": "You are a helpful assistant",
      "user_prompt": "{{user_input}}",
      "temperature": 0.7,
      "max_tokens": 1000,
      "api_key": "{{openrouter_api_key}}"  // Optional, falls back to env
    }

  All prompt fields support Liquid templating with input variables.
  """

  @behaviour Backend.Pipelines.NodeExecutor

  require Logger

  @impl true
  def execute(node, inputs, _context) do
    with {:ok, provider} <- get_provider(node),
         {:ok, model} <- get_model(node),
         {:ok, system_prompt} <- render_system_prompt(node, inputs),
         {:ok, user_prompt} <- render_user_prompt(node, inputs),
         {:ok, api_key} <- get_api_key(node, provider) do
      temperature = get_config(node, "temperature", 0.7)
      max_tokens = get_config(node, "max_tokens", 1000)

      call_llm_api(provider, model, system_prompt, user_prompt, temperature, max_tokens, api_key)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate_config(node) do
    required = ["model", "user_prompt"]

    missing =
      Enum.filter(required, fn key ->
        config = node.config || %{}
        not (Map.has_key?(config, key) or Map.has_key?(config, String.to_atom(key)))
      end)

    if missing == [] do
      :ok
    else
      {:error, "LLM node requires: #{Enum.join(missing, ", ")}"}
    end
  end

  # Private helpers

  defp get_provider(node) do
    provider = get_config(node, "provider", "openrouter")
    {:ok, String.to_atom(provider)}
  end

  defp get_model(node) do
    model = get_config(node, "model")

    if model do
      {:ok, model}
    else
      {:error, "Missing 'model' in config"}
    end
  end

  defp render_system_prompt(node, inputs) do
    system_template = get_config(node, "system_prompt", "You are a helpful assistant.")

    try do
      {:ok, template} = Solid.parse(system_template)
      rendered = Solid.render(template, inputs) |> to_string()
      {:ok, rendered}
    rescue
      error -> {:error, "Failed to render system prompt: #{Exception.message(error)}"}
    end
  end

  defp render_user_prompt(node, inputs) do
    user_template = get_config(node, "user_prompt")

    if user_template do
      try do
        {:ok, template} = Solid.parse(user_template)
        rendered = Solid.render(template, inputs) |> to_string()
        {:ok, rendered}
      rescue
        error -> {:error, "Failed to render user prompt: #{Exception.message(error)}"}
      end
    else
      {:error, "Missing 'user_prompt' in config"}
    end
  end

  defp get_api_key(node, provider) do
    # Try node config first, then environment
    api_key = get_config(node, "api_key")

    api_key =
      api_key ||
        case provider do
          :openrouter -> Application.get_env(:backend, :openrouter_api_key)
          :xai -> Application.get_env(:backend, :xai_api_key)
          _ -> nil
        end

    if api_key do
      {:ok, api_key}
    else
      {:error, "No API key found for provider #{provider}"}
    end
  end

  defp call_llm_api(provider, model, system_prompt, user_prompt, temperature, max_tokens, api_key) do
    start_time = System.monotonic_time(:millisecond)

    case provider do
      :openrouter ->
        call_openrouter(model, system_prompt, user_prompt, temperature, max_tokens, api_key)

      :xai ->
        call_xai(model, system_prompt, user_prompt, temperature, max_tokens, api_key)

      _ ->
        {:error, "Unsupported provider: #{provider}"}
    end
    |> case do
      {:ok, response_text, tokens} ->
        duration = System.monotonic_time(:millisecond) - start_time

        output = %{
          "text" => response_text,
          "model" => model,
          "provider" => to_string(provider)
        }

        metadata = %{
          "duration_ms" => duration,
          "tokens_used" => tokens,
          "model" => model,
          "provider" => to_string(provider),
          "temperature" => temperature,
          "max_tokens" => max_tokens
        }

        {:ok, output, metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_openrouter(model, system_prompt, user_prompt, temperature, max_tokens, api_key) do
    url = "https://openrouter.ai/api/v1/chat/completions"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"HTTP-Referer", "https://github.com/pyrex41/elix"},
      {"X-Title", "Elix Pipeline"}
    ]

    body = %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => user_prompt}
      ],
      "temperature" => temperature,
      "max_tokens" => max_tokens
    }

    Logger.info("[LlmNode] Calling OpenRouter with model: #{model}")

    case Req.post(url, json: body, headers: headers, receive_timeout: 90_000) do
      {:ok, %{status: 200, body: response_body}} ->
        text = get_in(response_body, ["choices", Access.at(0), "message", "content"])
        tokens = get_in(response_body, ["usage", "total_tokens"]) || 0

        if text do
          {:ok, text, tokens}
        else
          {:error, "No response text in OpenRouter response"}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[LlmNode] OpenRouter API returned status #{status}: #{inspect(body)}")
        {:error, "OpenRouter API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[LlmNode] OpenRouter API request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp call_xai(model, system_prompt, user_prompt, temperature, max_tokens, api_key) do
    url = "https://api.x.ai/v1/chat/completions"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => user_prompt}
      ],
      "temperature" => temperature,
      "max_tokens" => max_tokens,
      "stream" => false
    }

    Logger.info("[LlmNode] Calling xAI with model: #{model}")

    case Req.post(url, json: body, headers: headers, receive_timeout: 90_000) do
      {:ok, %{status: 200, body: response_body}} ->
        text = get_in(response_body, ["choices", Access.at(0), "message", "content"])
        tokens = get_in(response_body, ["usage", "total_tokens"]) || 0

        if text do
          {:ok, text, tokens}
        else
          {:error, "No response text in xAI response"}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[LlmNode] xAI API returned status #{status}: #{inspect(body)}")
        {:error, "xAI API request failed with status #{status}"}

      {:error, exception} ->
        Logger.error("[LlmNode] xAI API request failed: #{inspect(exception)}")
        {:error, Exception.message(exception)}
    end
  end

  defp get_config(node, key, default \\ nil) do
    config = node.config || %{}

    Map.get(config, key) ||
      Map.get(config, String.to_atom(key)) ||
      default
  end
end
