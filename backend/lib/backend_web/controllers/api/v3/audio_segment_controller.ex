defmodule BackendWeb.Api.V3.AudioSegmentController do
  @moduledoc """
  Serves ephemeral audio segments used for MusicGen continuation.
  """
  use BackendWeb, :controller

  alias Backend.Services.AudioSegmentStore

  def show(conn, %{"token" => token}) do
    case AudioSegmentStore.fetch(token) do
      {:ok, blob} ->
        serve_audio_blob(conn, blob, "segment_#{token}.mp3")

      {:error, :expired} ->
        send_json_error(conn, :not_found, "Audio segment expired")

      {:error, :not_found} ->
        send_json_error(conn, :not_found, "Audio segment not found")

      {:error, :store_not_ready} ->
        send_json_error(conn, :service_unavailable, "Audio segment store unavailable")
    end
  end

  defp serve_audio_blob(conn, audio_blob, filename) do
    etag = calculate_etag(audio_blob)

    case get_req_header(conn, "if-none-match") do
      [^etag] ->
        conn
        |> put_resp_header("etag", etag)
        |> send_resp(304, "")

      _ ->
        conn
        |> put_resp_header("content-type", "audio/mpeg")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("content-length", to_string(byte_size(audio_blob)))
        |> put_resp_header("etag", etag)
        |> send_resp(200, audio_blob)
    end
  end

  defp calculate_etag(blob) do
    :crypto.hash(:sha256, blob)
    |> Base.encode16(case: :lower)
  end

  defp send_json_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
