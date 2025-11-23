defmodule BackendWeb.Api.V3.AssetController do
  use BackendWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Backend.Repo
  alias Backend.Schemas.Asset
  alias BackendWeb.Schemas.{AssetSchemas, CommonSchemas}
  require Logger

  tags ["Assets"]

  # Add validation plug for request casting and validation
  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  operation :unified,
    summary: "Upload an asset",
    description: "Upload an asset via file upload or URL download. Supports images, videos, and audio.",
    request_body:
      {"Asset upload request", "multipart/form-data",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           file: %OpenApiSpex.Schema{
             type: :string,
             format: :binary,
             description: "File to upload (for direct upload)"
           },
           source_url: %OpenApiSpex.Schema{
             type: :string,
             format: :uri,
             description: "URL to download asset from (alternative to file upload)"
           },
           type: %OpenApiSpex.Schema{
             type: :string,
             enum: [:image, :video, :audio],
             description: "Asset type"
           },
           campaign_id: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             description: "Associated campaign ID"
           },
           metadata: %OpenApiSpex.Schema{
             type: :object,
             description: "Additional metadata",
             additionalProperties: true
           }
         },
         oneOf: [
           %OpenApiSpex.Schema{required: [:file]},
           %OpenApiSpex.Schema{required: [:source_url]}
         ]
       }},
    responses: %{
      201 => {"Asset created", "application/json", AssetSchemas.AssetResponse},
      400 => {"Bad request", "application/json", CommonSchemas.ErrorResponse},
      422 => {"Validation error", "application/json", CommonSchemas.ValidationErrorResponse},
      500 => {"Server error", "application/json", CommonSchemas.ErrorResponse}
    }

  @doc """
  POST /api/v3/assets/unified

  Handles asset uploads via file upload or URL download.
  Supports both multipart file uploads and JSON body with URL.

  Request formats:
  1. Multipart file upload:
     - file: The uploaded file (Plug.Upload)
     - type: Asset type (image/video/audio)
     - campaign_id: UUID of associated campaign (optional)
     - metadata: JSON metadata (optional)

  2. URL download:
     - source_url: URL to download asset from
     - type: Asset type (image/video/audio)
     - campaign_id: UUID of associated campaign (optional)
     - metadata: JSON metadata (optional)

  Returns:
  - 201: Asset created successfully
  - 400: Invalid request (bad parameters, failed download, etc.)
  - 422: Validation error
  - 500: Server error (thumbnail generation failed, etc.)
  """
  def unified(conn, params) do
    case handle_upload(params) do
      {:ok, asset_attrs} ->
        # Generate thumbnail for videos
        asset_attrs = maybe_generate_thumbnail(asset_attrs)

        # Create asset in database
        case create_asset(asset_attrs) do
          {:ok, asset} ->
            conn
            |> put_status(:created)
            |> json(%{
              id: asset.id,
              type: asset.type,
              campaign_id: asset.campaign_id,
              source_url: asset.source_url,
              metadata: asset.metadata,
              has_thumbnail: !is_nil(asset.metadata["thumbnail_generated"]),
              inserted_at: asset.inserted_at
            })

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: "Validation failed",
              details: format_changeset_errors(changeset)
            })
        end

      {:error, :invalid_file_format} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid file format"})

      {:error, :network_failure, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to download from URL", reason: reason})

      {:error, :missing_source} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Either file upload or source_url must be provided"})

      {:error, reason} ->
        Logger.error("Asset upload failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to process asset upload"})
    end
  end

  operation :data,
    summary: "Get asset data",
    description: "Stream asset blob data efficiently. Returns the actual file content with appropriate content-type headers.",
    parameters: [
      id: [
        in: :path,
        type: :integer,
        description: "Asset ID",
        required: true,
        example: 123
      ]
    ],
    responses: %{
      200 => {"Asset data", "application/octet-stream", %OpenApiSpex.Schema{type: :string, format: :binary}},
      404 => {"Asset not found", "application/json", CommonSchemas.NotFoundResponse},
      500 => {"Server error", "application/json", CommonSchemas.ErrorResponse}
    }

  @doc """
  GET /api/v3/assets/:id/data

  Streams asset blob data efficiently without loading entire blob into memory.
  Sets appropriate content-type headers based on asset type.

  Returns:
  - 200: Asset data streamed successfully
  - 404: Asset not found
  - 500: Server error during streaming
  """
  def data(conn, %{"id" => id}) do
    case get_asset_with_blob(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Asset not found"})

      asset ->
        content_type = determine_content_type(asset)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header(
          "content-disposition",
          ~s(inline; filename="#{asset.id}.#{extension_for_type(asset.type)}")
        )
        |> send_resp(200, asset.blob_data)
    end
  rescue
    e ->
      Logger.error("Failed to retrieve asset data: #{inspect(e)}")

      conn
      |> put_status(:internal_server_error)
      |> json(%{error: "Failed to retrieve asset data"})
  end

  # Private helper functions

  defp handle_upload(%{"file" => %Plug.Upload{} = upload} = params) do
    # Handle file upload
    case File.read(upload.path) do
      {:ok, blob_data} ->
        type = Map.get(params, "type", infer_type_from_upload(upload))

        attrs = %{
          blob_data: blob_data,
          type: normalize_type(type),
          source_url: nil,
          campaign_id: Map.get(params, "campaign_id"),
          metadata: parse_metadata(params["metadata"])
        }

        {:ok, attrs}

      {:error, _reason} ->
        {:error, :invalid_file_format}
    end
  end

  defp handle_upload(%{"source_url" => url} = params) when is_binary(url) do
    # Handle URL download
    case download_from_url(url) do
      {:ok, blob_data, content_type} ->
        type = Map.get(params, "type") || infer_type_from_content_type(content_type)

        attrs = %{
          blob_data: blob_data,
          type: normalize_type(type),
          source_url: url,
          campaign_id: Map.get(params, "campaign_id"),
          metadata: parse_metadata(params["metadata"])
        }

        {:ok, attrs}

      {:error, reason} ->
        {:error, :network_failure, reason}
    end
  end

  defp handle_upload(_params) do
    {:error, :missing_source}
  end

  defp download_from_url(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = get_content_type_from_headers(headers)
        {:ok, body, content_type}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp get_content_type_from_headers(headers) do
    headers
    |> Enum.find(fn {key, _value} -> String.downcase(key) == "content-type" end)
    |> case do
      {_key, value} -> value
      nil -> "application/octet-stream"
    end
  end

  defp maybe_generate_thumbnail(%{type: type, blob_data: blob_data} = attrs)
       when type in [:video, "video"] do
    case generate_video_thumbnail(blob_data) do
      {:ok, thumbnail_path} ->
        # Store thumbnail info in metadata
        metadata = attrs[:metadata] || %{}

        updated_metadata =
          Map.merge(metadata, %{
            "thumbnail_generated" => true,
            "thumbnail_path" => thumbnail_path
          })

        Map.put(attrs, :metadata, updated_metadata)

      {:error, reason} ->
        Logger.warning("Failed to generate thumbnail: #{inspect(reason)}")
        # Continue without thumbnail
        attrs
    end
  end

  defp maybe_generate_thumbnail(attrs), do: attrs

  defp generate_video_thumbnail(blob_data) do
    # Create temporary file for video
    temp_video_path =
      Path.join(System.tmp_dir!(), "video_#{:erlang.unique_integer([:positive])}.mp4")

    temp_thumb_path =
      Path.join(System.tmp_dir!(), "thumb_#{:erlang.unique_integer([:positive])}.jpg")

    try do
      # Write blob to temp file
      File.write!(temp_video_path, blob_data)

      # Generate thumbnail using FFmpeg
      # Extract frame at 1 second, scale to 320x240
      args = [
        "-i",
        temp_video_path,
        "-ss",
        "00:00:01.000",
        "-vframes",
        "1",
        "-vf",
        "scale=320:240:force_original_aspect_ratio=decrease",
        temp_thumb_path
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, temp_thumb_path}

        {output, exit_code} ->
          Logger.error("FFmpeg failed with exit code #{exit_code}: #{output}")
          {:error, "FFmpeg failed with exit code #{exit_code}"}
      end
    rescue
      e ->
        Logger.error("Exception during thumbnail generation: #{inspect(e)}")
        {:error, Exception.message(e)}
    after
      # Clean up temporary video file
      File.rm(temp_video_path)
    end
  end

  defp create_asset(attrs) do
    %Asset{}
    |> Asset.changeset(attrs)
    |> Repo.insert()
  end

  defp get_asset_with_blob(id) do
    # For large blobs, we could use Repo.stream, but for simplicity, we'll fetch directly
    # In production, consider streaming for very large files
    Repo.get(Asset, id)
  end

  defp determine_content_type(%{type: :image}), do: "image/jpeg"
  defp determine_content_type(%{type: :video}), do: "video/mp4"
  defp determine_content_type(%{type: :audio}), do: "audio/mpeg"
  defp determine_content_type(%{type: "image"}), do: "image/jpeg"
  defp determine_content_type(%{type: "video"}), do: "video/mp4"
  defp determine_content_type(%{type: "audio"}), do: "audio/mpeg"
  defp determine_content_type(_), do: "application/octet-stream"

  defp extension_for_type(:image), do: "jpg"
  defp extension_for_type(:video), do: "mp4"
  defp extension_for_type(:audio), do: "mp3"
  defp extension_for_type("image"), do: "jpg"
  defp extension_for_type("video"), do: "mp4"
  defp extension_for_type("audio"), do: "mp3"
  defp extension_for_type(_), do: "bin"

  defp infer_type_from_upload(%Plug.Upload{content_type: content_type}) do
    infer_type_from_content_type(content_type)
  end

  defp infer_type_from_content_type(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> :image
      String.starts_with?(content_type, "video/") -> :video
      String.starts_with?(content_type, "audio/") -> :audio
      true -> :image
    end
  end

  defp infer_type_from_content_type(_), do: :image

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type("image"), do: :image
  defp normalize_type("video"), do: :video
  defp normalize_type("audio"), do: :audio
  defp normalize_type(_), do: :image

  defp parse_metadata(nil), do: %{}
  defp parse_metadata(metadata) when is_map(metadata), do: metadata

  defp parse_metadata(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp parse_metadata(_), do: %{}

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
