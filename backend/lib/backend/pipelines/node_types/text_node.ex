defmodule Backend.Pipelines.NodeTypes.TextNode do
  @moduledoc """
  Text Node: Outputs static or templated text using Liquid templating.

  Configuration:
    {
      "content": "Hello {{name}}, your order {{order_id}} is ready!"
    }

  Input variables from previous nodes are available in the template.
  """

  @behaviour Backend.Pipelines.NodeExecutor

  @impl true
  def execute(node, inputs, _context) do
    content_template = get_config(node, "content", "")

    try do
      # Render the Liquid template with input data
      {:ok, template} = Solid.parse(content_template)
      rendered = Solid.render(template, inputs) |> to_string()

      output = %{
        "text" => rendered,
        "original_template" => content_template
      }

      metadata = %{
        "template_length" => String.length(content_template),
        "output_length" => String.length(rendered),
        "variables_used" => extract_variables(content_template)
      }

      {:ok, output, metadata}
    rescue
      error ->
        {:error, "Failed to render template: #{Exception.message(error)}"}
    end
  end

  @impl true
  def validate_config(node) do
    if get_config(node, "content") do
      :ok
    else
      {:error, "Text node requires 'content' field in config"}
    end
  end

  # Private helpers

  defp get_config(node, key, default \\ nil) do
    config = node.config || %{}

    Map.get(config, key) ||
      Map.get(config, String.to_atom(key)) ||
      default
  end

  defp extract_variables(template) do
    # Extract variable names from Liquid template syntax {{variable}}
    Regex.scan(~r/\{\{\s*(\w+)\s*\}\}/, template)
    |> Enum.map(fn [_, var] -> var end)
    |> Enum.uniq()
  end
end
