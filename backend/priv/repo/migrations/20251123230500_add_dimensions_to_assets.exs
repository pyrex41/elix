defmodule Backend.Repo.Migrations.AddDimensionsToAssets do
  use Ecto.Migration
  import Ecto.Query
  require Logger
  alias ExImageInfo

  defmodule Asset do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "assets" do
      field(:type, :string)
      field(:blob_data, :binary)
      field(:metadata, :map)
    end
  end

  def up do
    columns = get_column_names("assets")

    unless "width" in columns do
      execute("ALTER TABLE assets ADD COLUMN width INTEGER;")
    end

    unless "height" in columns do
      execute("ALTER TABLE assets ADD COLUMN height INTEGER;")
    end

    flush()
    populate_dimensions()
  end

  def down do
    :ok
  end

  defp populate_dimensions do
    repo = repo()

    query =
      from(a in Asset,
        where: a.type == "image",
        select: %{id: a.id, blob_data: a.blob_data, metadata: a.metadata}
      )

    repo.transaction(fn ->
      repo.stream(query)
      |> Enum.each(fn asset ->
        case determine_dimensions(asset) do
          {width, height} when is_integer(width) and is_integer(height) ->
            repo.update_all(
              from(a in "assets", where: a.id == ^asset.id),
              set: [width: width, height: height]
            )

          _ ->
            :ok
        end
      end)
    end)
  end

  defp determine_dimensions(%{metadata: metadata} = asset) do
    metadata = metadata || %{}

    width = parse_dimension(Map.get(metadata, "width") || Map.get(metadata, :width))
    height = parse_dimension(Map.get(metadata, "height") || Map.get(metadata, :height))

    cond do
      is_integer(width) and is_integer(height) ->
        {width, height}

      is_binary(asset.blob_data) and byte_size(asset.blob_data) > 0 ->
        case ExImageInfo.info(asset.blob_data) do
          {:ok, %{width: w, height: h}} ->
            {w, h}

          {:error, reason} ->
            Logger.debug(
              "[Migration] Failed to read image info for #{asset.id}: #{inspect(reason)}"
            )

            {nil, nil}
        end

      true ->
        {nil, nil}
    end
  rescue
    _ ->
      {nil, nil}
  end

  defp parse_dimension(value) when is_integer(value), do: value

  defp parse_dimension(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_dimension(_), do: nil

  defp get_column_names(table) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table});")
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end
end
