defmodule BackendWeb.Api.V3.AssetController do
  use BackendWeb, :controller

  alias Backend.Repo
  alias Backend.Schemas.{Asset, Campaign}
  alias BackendWeb.Schemas.{AssetSchemas, CommonSchemas}
  alias OpenApiSpex.Operation
  import Ecto.Query
  require Logger

  @default_limit 25
  @max_limit 1000

  @doc """
  OpenAPI operation specification callback
  """
  def open_api_operation(action) do
    operation = String.to_existing_atom("#{action}_operation")
    apply(__MODULE__, operation, [])
  end

  def index_operation do
    %Operation{
      tags: ["Assets"],
      summary: "List all assets",
      description: "Retrieve a paginated list of assets with optional filtering",
      operationId: "AssetController.index",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:campaign_id, :query, :string, "Filter by campaign ID"),
        Operation.parameter(:type, :query, :string, "Filter by asset type (image, video, audio)"),
        Operation.parameter(:limit, :query, :integer, "Number of results per page (default: 25, max: 1000)"),
        Operation.parameter(:offset, :query, :integer, "Pagination offset (default: 0)")
      ],
      responses: %{
        200 => Operation.response("Assets", "application/json", AssetSchemas.AssetsResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def show_operation do
    %Operation{
      tags: ["Assets"],
      summary: "Get asset by ID",
      description: "Retrieve a single asset by its ID",
      operationId: "AssetController.show",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Asset ID", example: "323e4567-e89b-12d3-a456-426614174000")
      ],
      responses: %{
        200 => Operation.response("Asset", "application/json", AssetSchemas.AssetResponse),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def create_operation do
    %Operation{
      tags: ["Assets"],
      summary: "Create a new asset",
      description: "Create a new asset via file upload or source URL",
      operationId: "AssetController.create",
      security: [%{"api_key" => []}],
      requestBody: Operation.request_body("Asset attributes", "application/json", AssetSchemas.AssetRequest, required: true),
      responses: %{
        201 => Operation.response("Asset created", "application/json", AssetSchemas.AssetResponse),
        400 => Operation.response("Bad Request", "application/json", CommonSchemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", CommonSchemas.ValidationErrorResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def delete_operation do
    %Operation{
      tags: ["Assets"],
      summary: "Delete an asset",
      description: "Delete an asset by ID",
      operationId: "AssetController.delete",
      security: [%{"api_key" => []}],
      parameters: [
        Operation.parameter(:id, :path, :string, "Asset ID", example: "323e4567-e89b-12d3-a456-426614174000")
      ],
      responses: %{
        204 => Operation.response("No Content", "application/json", CommonSchemas.NoContentResponse),
        404 => Operation.response("Not Found", "application/json", CommonSchemas.ErrorResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def from_url_operation do
    %Operation{
      tags: ["Assets"],
      summary: "Create asset from URL",
      description: "Create a new asset by downloading from a URL",
      operationId: "AssetController.from_url",
      security: [%{"api_key" => []}],
      requestBody: Operation.request_body("Asset from URL", "application/json", AssetSchemas.AssetFromUrlRequest, required: true),
      responses: %{
        201 => Operation.response("Asset created", "application/json", AssetSchemas.AssetResponse),
        400 => Operation.response("Bad Request", "application/json", CommonSchemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", CommonSchemas.ValidationErrorResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def from_urls_operation do
    %Operation{
      tags: ["Assets"],
      summary: "Create multiple assets from URLs",
      description: "Create multiple assets by downloading from URLs",
      operationId: "AssetController.from_urls",
      security: [%{"api_key" => []}],
      requestBody: Operation.request_body("Assets from URLs", "application/json", AssetSchemas.AssetFromUrlsRequest, required: true),
      responses: %{
        201 => Operation.response("Assets created", "application/json", AssetSchemas.AssetsResponse),
        400 => Operation.response("Bad Request", "application/json", CommonSchemas.ErrorResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def unified_operation do
    %Operation{
      tags: ["Assets"],
      summary: "Create asset (unified endpoint)",
      description: "Create a new asset via file upload or URL download. Supports both multipart file uploads and JSON with URL.",
      operationId: "AssetController.unified",
      security: [%{"api_key" => []}],
      requestBody: Operation.request_body("Asset upload or URL", "application/json", AssetSchemas.AssetRequest, required: true),
      responses: %{
        201 => Operation.response("Asset created", "application/json", AssetSchemas.AssetResponse),
        400 => Operation.response("Bad Request", "application/json", CommonSchemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", CommonSchemas.ValidationErrorResponse),
        401 => Operation.response("Unauthorized", "application/json", CommonSchemas.ErrorResponse)
      }
    }
  end

  def index(conn, params) do
    params = normalize_asset_params(params)
    {limit, offset} = extract_pagination(params)

    base_query =
      Asset
      |> maybe_filter(:campaign_id, params["campaign_id"])
      |> maybe_filter(:type, params["asset_type"] || params["type"])

    total = Repo.aggregate(base_query, :count, :id)

    assets =
      base_query
      |> order_by([a], desc: a.inserted_at)
      |> offset(^offset)
      |> limit(^limit)
      |> Repo.all()
      |> Repo.preload(:campaign)

    json(conn, %{
      data: Enum.map(assets, &asset_json/1),
      meta: %{total: total, limit: limit, offset: offset}
    })
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Asset, id) |> Repo.preload(:campaign) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Asset not found"})

      asset ->
        json(conn, %{data: asset_json(asset)})
    end
  end

  def create(conn, params) do
    params = normalize_asset_params(params)

    case handle_upload(params) do
      {:ok, asset_attrs} ->
        case create_asset(asset_attrs) do
          {:ok, asset} ->
            asset = Repo.preload(asset, :campaign)

            conn
            |> put_status(:created)
            |> json(%{data: asset_json(asset)})

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
        Logger.error("Asset creation failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to create asset"})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Asset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Asset not found"})

      asset ->
        Repo.delete!(asset)
        send_resp(conn, :no_content, "")
    end
  end

  def from_url(conn, params) do
    params = normalize_asset_params(params)

    with {:ok, asset_attrs} <- handle_upload(params),
         {:ok, asset} <- create_asset(asset_attrs) do
      asset = Repo.preload(asset, :campaign)

      conn
      |> put_status(:created)
      |> json(%{data: asset_json(asset)})
    else
      {:error, :missing_source} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "source_url is required"})

      {:error, :network_failure, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to download from URL", reason: reason})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Validation failed",
          details: format_changeset_errors(changeset)
        })

      {:error, reason} ->
        Logger.error("Asset download failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to create asset"})
    end
  end

  def from_urls(conn, params) do
    entries =
      params["assets"] || params["items"] || params["requests"] ||
        params["sources"] || []

    if is_list(entries) and entries != [] do
      {results, failures} =
        Enum.reduce(entries, {[], []}, fn entry, {ok_acc, error_acc} ->
          normalized = normalize_asset_params(entry)

          case handle_upload(normalized) do
            {:ok, attrs} ->
              case create_asset(attrs) do
                {:ok, asset} ->
                  asset = Repo.preload(asset, :campaign)
                  {[asset_json(asset) | ok_acc], error_acc}

                {:error, %Ecto.Changeset{} = changeset} ->
                  message = format_changeset_errors(changeset)
                  {ok_acc, [%{source: normalized["source_url"], error: message} | error_acc]}
              end

            {:error, :missing_source} ->
              {
                ok_acc,
                [%{source: normalized["source_url"], error: "source_url is required"} | error_acc]
              }

            {:error, :network_failure, reason} ->
              {ok_acc, [%{source: normalized["source_url"], error: reason} | error_acc]}

            {:error, reason} ->
              {ok_acc,
               [%{source: normalized["source_url"], error: to_string(reason)} | error_acc]}
          end
        end)

      conn
      |> put_status(:created)
      |> json(%{
        data: Enum.reverse(results),
        meta: %{
          created: length(results),
          failed: length(failures),
          errors: Enum.reverse(failures)
        }
      })
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "assets must be a non-empty array"})
    end
  end

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
    params = normalize_asset_params(params)

    case handle_upload(params) do
      {:ok, asset_attrs} ->
        # Generate thumbnail for videos
        asset_attrs = maybe_generate_thumbnail(asset_attrs)

        # Create asset in database
        case create_asset(asset_attrs) do
          {:ok, asset} ->
            asset = Repo.preload(asset, :campaign)

            conn
            |> put_status(:created)
            |> json(%{
              data: asset_json(asset),
              meta: %{
                has_thumbnail: not is_nil(get_in(asset.metadata || %{}, ["thumbnail_generated"]))
              }
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
        case load_asset_body(asset) do
          {:ok, body, content_type} ->
            content_type = normalize_content_type(content_type, asset)

            conn
            |> put_resp_content_type(content_type)
            |> put_resp_header(
              "content-disposition",
              ~s(inline; filename="#{asset.id}.#{extension_for_type(asset.type)}")
            )
            |> send_resp(200, body)

          {:error, reason} ->
            Logger.error("Failed to load asset #{asset.id} body: #{inspect(reason)}")

            conn
            |> put_status(:bad_gateway)
            |> json(%{error: "Asset blob unavailable"})
        end
    end
  rescue
    e ->
      Logger.error("Failed to retrieve asset data: #{inspect(e)}")

      conn
      |> put_status(:internal_server_error)
      |> json(%{error: "Failed to retrieve asset data"})
  end

  def thumbnail(conn, %{"id" => id}) do
    case Repo.get(Asset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Asset not found"})

      asset ->
        case load_thumbnail_blob(asset) do
          {:ok, blob} ->
            conn
            |> put_resp_content_type("image/jpeg")
            |> put_resp_header("cache-control", "public, max-age=86400")
            |> send_resp(200, blob)

          {:error, :not_available} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Thumbnail not available"})

          {:error, reason} ->
            Logger.error("Failed to serve thumbnail for asset #{asset.id}: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to serve thumbnail"})
        end
    end
  end

  # Private helper functions

  defp normalize_asset_params(%{} = params) do
    params =
      params
      |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
      |> Enum.into(%{})

    metadata =
      Map.get(params, "metadata") ||
        Map.get(params, "meta") ||
        Map.get(params, "tags")

    params
    |> Map.put_new("campaign_id", params["campaign_id"] || params["campaignId"])
    |> Map.put_new(
      "source_url",
      params["source_url"] || params["sourceUrl"] || params["url"]
    )
    |> Map.put_new("type", params["type"] || params["asset_type"])
    |> Map.put("metadata", metadata)
  end

  defp normalize_asset_params(params) when is_list(params), do: params
  defp normalize_asset_params(params), do: params || %{}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp extract_pagination(params) do
    limit =
      params["limit"]
      |> to_integer(@default_limit)
      |> min(@max_limit)
      |> max(1)

    offset =
      params["offset"]
      |> to_integer(0)
      |> max(0)

    {limit, offset}
  end

  defp to_integer(nil, default), do: default
  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> default
    end
  end

  defp to_integer(_, default), do: default

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, :type, value) do
    normalized =
      case value do
        v when is_atom(v) ->
          v

        v when is_binary(v) ->
          case String.downcase(v) do
            "image" -> :image
            "video" -> :video
            "audio" -> :audio
            _ -> :unknown
          end

        _ ->
          :unknown
      end

    if normalized in Asset.asset_types() do
      where(query, [a], a.type == ^normalized)
    else
      query
    end
  end

  defp maybe_filter(query, :campaign_id, value) do
    where(query, [a], a.campaign_id == ^value)
  end

  defp asset_json(asset) do
    metadata = asset.metadata || %{}
    type = asset_type_string(asset)

    base = %{
      id: asset.id,
      userId: metadata_value(metadata, ["userId", "user_id"]) || "",
      clientId: asset_client_id(asset, metadata),
      campaignId: asset.campaign_id,
      name: asset_name(metadata, asset.id),
      url: asset_data_url(asset.id),
      size: parse_integer(metadata["size"]),
      uploadedAt: format_timestamp(asset.inserted_at),
      tags: parse_tags(metadata["tags"]),
      thumbnailBlobId: metadata_value(metadata, ["thumbnail_blob_id", "thumbnailBlobId"]),
      sourceUrl: asset.source_url,
      type: type,
      format: asset_format(asset, metadata)
    }

    case type do
      "image" ->
        Map.merge(base, %{
          width: parse_integer(metadata["width"], 0),
          height: parse_integer(metadata["height"], 0)
        })

      "video" ->
        Map.merge(base, %{
          width: parse_integer(metadata["width"], 0),
          height: parse_integer(metadata["height"], 0),
          duration: parse_integer(metadata["duration"], 0),
          thumbnailUrl: asset_thumbnail_url(asset.id)
        })

      "audio" ->
        Map.merge(base, %{
          duration: parse_integer(metadata["duration"], 0),
          waveformUrl: metadata_value(metadata, ["waveform_url", "waveformUrl"])
        })

      _ ->
        base
    end
  end

  defp asset_client_id(%{campaign: %Campaign{client_id: client_id}}, _metadata), do: client_id

  defp asset_client_id(_asset, metadata) do
    metadata_value(metadata, ["clientId", "client_id"])
  end

  defp asset_name(metadata, fallback) do
    metadata["name"] ||
      metadata["original_name"] ||
      metadata["originalName"] ||
      fallback
  end

  defp asset_type_string(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp asset_type_string(%{type: type}) when is_binary(type), do: type
  defp asset_type_string(_), do: "image"

  defp asset_data_url(id), do: "/api/v3/assets/#{id}/data"
  defp asset_thumbnail_url(id), do: "/api/v3/assets/#{id}/thumbnail"

  defp format_timestamp(nil), do: nil
  defp format_timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(value) when is_binary(value), do: value
  defp format_timestamp(_), do: nil

  defp parse_integer(value, default \\ nil)
  defp parse_integer(nil, default), do: default
  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(value, _default) when is_float(value), do: trunc(value)

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_integer(_, default), do: default

  defp parse_tags(nil), do: nil
  defp parse_tags(tags) when is_list(tags), do: tags

  defp parse_tags(tags) when is_binary(tags) do
    case Jason.decode(tags) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> nil
    end
  end

  defp parse_tags(_), do: nil

  defp metadata_value(metadata, keys) do
    Enum.find_value(List.wrap(keys), fn key ->
      case key do
        binary when is_binary(binary) -> Map.get(metadata, binary)
        atom when is_atom(atom) -> Map.get(metadata, atom)
      end
    end)
  end

  defp asset_format(_asset, %{"format" => format}) when is_binary(format),
    do: String.downcase(format)

  defp asset_format(_asset, %{"format" => format}) when is_atom(format),
    do: format |> Atom.to_string() |> String.downcase()

  defp asset_format(_asset, %{"content_type" => content_type}) when is_binary(content_type) do
    content_type
    |> String.split("/")
    |> List.last()
    |> String.downcase()
  end

  defp asset_format(asset, _metadata) do
    case asset.source_url do
      nil ->
        nil

      url ->
        url
        |> URI.parse()
        |> Map.get(:path)
        |> case do
          nil -> nil
          path -> path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
        end
    end
  end

  defp load_thumbnail_blob(%Asset{metadata: metadata} = asset) do
    metadata = metadata || %{}
    thumbnail_path = metadata["thumbnail_path"]

    cond do
      is_binary(thumbnail_path) and File.exists?(thumbnail_path) ->
        File.read(thumbnail_path)

      asset.type in [:image, "image"] and is_binary(asset.blob_data) ->
        {:ok, asset.blob_data}

      asset.type in [:video, "video"] and is_binary(asset.blob_data) ->
        case generate_video_thumbnail(asset.blob_data) do
          {:ok, path} ->
            _ = maybe_persist_thumbnail_path(asset, path)
            File.read(path)

          error ->
            error
        end

      true ->
        {:error, :not_available}
    end
  end

  defp maybe_persist_thumbnail_path(asset, path) do
    metadata =
      (asset.metadata || %{})
      |> Map.put("thumbnail_generated", true)
      |> Map.put("thumbnail_path", path)

    asset
    |> Asset.changeset(%{metadata: metadata})
    |> Repo.update()
  end

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

  defp get_asset_with_blob(id), do: Repo.get(Asset, id)

  defp load_asset_body(%Asset{blob_data: data} = asset) when is_binary(data) do
    {:ok, data, determine_content_type(asset)}
  end

  defp load_asset_body(%Asset{source_url: url} = asset)
       when is_binary(url) and url != "" do
    fetch_remote_asset(url, asset)
  end

  defp load_asset_body(_), do: {:error, :no_blob_available}

  defp fetch_remote_asset(url, asset) do
    if String.starts_with?(url, ["http://", "https://"]) do
      case Req.get(url, redirect: :follow, max_redirects: 3, receive_timeout: 30_000) do
        {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
          content_type =
            headers
            |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end)
            |> Map.get("content-type")

          {:ok, body, normalize_content_type(content_type, asset)}

        {:ok, %{status: status}} ->
          {:error, {:remote_status, status}}

        {:error, reason} ->
          {:error, {:remote_fetch_failed, reason}}
      end
    else
      {:error, :unsupported_source_url}
    end
  end

  defp determine_content_type(%{type: :image}), do: "image/jpeg"
  defp determine_content_type(%{type: :video}), do: "video/mp4"
  defp determine_content_type(%{type: :audio}), do: "audio/mpeg"
  defp determine_content_type(%{type: "image"}), do: "image/jpeg"
  defp determine_content_type(%{type: "video"}), do: "video/mp4"
  defp determine_content_type(%{type: "audio"}), do: "audio/mpeg"
  defp determine_content_type(_), do: "application/octet-stream"

  defp normalize_content_type(nil, asset), do: determine_content_type(asset)
  defp normalize_content_type("", asset), do: determine_content_type(asset)

  defp normalize_content_type(content_type, _asset) when is_binary(content_type) do
    content_type
  end

  defp normalize_content_type(_value, asset), do: determine_content_type(asset)

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
