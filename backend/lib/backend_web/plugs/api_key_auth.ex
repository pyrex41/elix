defmodule BackendWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Simple X-API-Key authentication plug.

  Looks for an `x-api-key` header and compares it against the configured key list.
  When no key is configured the plug becomes a no-op to avoid blocking local development.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  @header_name "x-api-key"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case configured_keys() do
      [] ->
        conn

      keys ->
        case get_req_header(conn, @header_name) do
          [provided] when provided in keys ->
            conn

          _ ->
            Logger.warning("[ApiKeyAuth] Missing or invalid #{@header_name} header")

            conn
            |> put_status(:unauthorized)
            |> put_resp_content_type("application/json")
            |> send_resp(
              :unauthorized,
              Jason.encode!(%{error: "missing or invalid #{@header_name} header"})
            )
            |> halt()
        end
    end
  end

  defp configured_keys do
    Application.get_env(:backend, :api_keys)
    |> case do
      nil -> Application.get_env(:backend, :api_key)
      value -> value
    end
    |> case do
      nil ->
        env = System.get_env("API_AUTH_KEY")

        if is_binary(env) and env != "" do
          [String.trim(env)]
        else
          []
        end

      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_list(value) ->
        Enum.flat_map(value, fn
          key when is_binary(key) -> [String.trim(key)]
          key -> [to_string(key)]
        end)

      _ ->
        []
    end
  end
end
