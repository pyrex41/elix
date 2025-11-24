defmodule Backend.Services.VideoMetadata do
  @moduledoc """
  Helpers for generating consistent video metadata, such as sequential names
  per campaign.
  """

  import Ecto.Query
  alias Backend.{Repo, Schemas.Job}

  @doc """
  Determine the next ordinal for a campaign's videos (1-indexed).
  """
  @spec next_video_sequence(String.t() | nil) :: pos_integer()
  def next_video_sequence(nil), do: 1

  def next_video_sequence(campaign_id) do
    query =
      from j in Job,
        where: fragment("json_extract(?, '$.campaign_id') = ?", j.parameters, ^campaign_id)

    (Repo.aggregate(query, :count, :id) || 0) + 1
  end

  @doc """
  Build a human friendly video name of the form \"{Campaign Name} {N}\".
  """
  @spec build_video_name(String.t() | nil, pos_integer()) :: String.t()
  def build_video_name(nil, sequence), do: "Video #{sequence}"
  def build_video_name("", sequence), do: "Video #{sequence}"

  def build_video_name(campaign_name, sequence) do
    "#{campaign_name} #{sequence}"
  end
end
