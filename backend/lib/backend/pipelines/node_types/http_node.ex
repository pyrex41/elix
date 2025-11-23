defmodule Backend.Pipelines.NodeTypes.HttpNode do
  @moduledoc """
  HTTP Request Node: Makes HTTP requests to external APIs.

  Configuration:
    {
      "url": "https://api.example.com/{{endpoint}}",
      "method": "POST",
      "headers": {
        "Authorization": "Bearer {{api_key}}",
        "Content-Type": "application/json"
      },
      "body": "{\"data\": \"{{input_data}}\"}"
    }

  All string values support Liquid templating with input variables.
  """

  @behaviour Backend.Pipelines.NodeExecutor

  @impl true
  def execute(node, inputs, _context) do
    with {:ok, url} <- render_url(node, inputs),
         {:ok, method} <- get_method(node),
         {:ok, headers} <- render_headers(node, inputs),
         {:ok, body} <- render_body(node, inputs) do
      make_request(method, url, headers, body)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate_config(node) do
    required = ["url", "method"]

    missing =
      Enum.filter(required, fn key ->
        config = node.config || %{}
        not (Map.has_key?(config, key) or Map.has_key?(config, String.to_atom(key)))
      end)

    if missing == [] do
      :ok
    else
      {:error, "HTTP request node requires: #{Enum.join(missing, ", ")}"}
    end
  end

  # Private helpers

  defp render_url(node, inputs) do
    url_template = get_config(node, "url")

    if url_template do
      try do
        {:ok, template} = Solid.parse(url_template)
        rendered = Solid.render(template, inputs) |> to_string()
        {:ok, rendered}
      rescue
        error -> {:error, "Failed to render URL: #{Exception.message(error)}"}
      end
    else
      {:error, "Missing 'url' in config"}
    end
  end

  defp get_method(node) do
    method = get_config(node, "method", "GET")

    method_atom =
      method
      |> to_string()
      |> String.downcase()
      |> String.to_atom()

    if method_atom in [:get, :post, :put, :patch, :delete] do
      {:ok, method_atom}
    else
      {:error, "Invalid HTTP method: #{method}"}
    end
  end

  defp render_headers(node, inputs) do
    headers = get_config(node, "headers", %{})

    try do
      rendered_headers =
        Enum.map(headers, fn {key, value} ->
          {:ok, template} = Solid.parse(to_string(value))
          rendered_value = Solid.render(template, inputs) |> to_string()
          {to_string(key), rendered_value}
        end)

      {:ok, rendered_headers}
    rescue
      error -> {:error, "Failed to render headers: #{Exception.message(error)}"}
    end
  end

  defp render_body(node, inputs) do
    body_template = get_config(node, "body")

    if body_template do
      try do
        {:ok, template} = Solid.parse(to_string(body_template))
        rendered = Solid.render(template, inputs) |> to_string()
        {:ok, rendered}
      rescue
        error -> {:error, "Failed to render body: #{Exception.message(error)}"}
      end
    else
      {:ok, nil}
    end
  end

  defp make_request(method, url, headers, body) do
    start_time = System.monotonic_time(:millisecond)

    request_opts =
      case body do
        nil -> [method: method, url: url, headers: headers]
        body -> [method: method, url: url, headers: headers, body: body]
      end

    case Req.request(request_opts) do
      {:ok, response} ->
        duration = System.monotonic_time(:millisecond) - start_time

        output = %{
          "status" => response.status,
          "headers" => Map.new(response.headers),
          "body" => response.body
        }

        metadata = %{
          "url" => url,
          "method" => to_string(method),
          "duration_ms" => duration,
          "status_code" => response.status
        }

        {:ok, output, metadata}

      {:error, error} ->
        {:error, "HTTP request failed: #{inspect(error)}"}
    end
  end

  defp get_config(node, key, default \\ nil) do
    config = node.config || %{}

    Map.get(config, key) ||
      Map.get(config, String.to_atom(key)) ||
      default
  end
end
