defmodule BackendWeb.Api.V3.VideoControllerTest do
  use BackendWeb.ConnCase, async: false
  alias Backend.Schemas.Job
  alias Backend.Schemas.SubJob
  alias Backend.Repo

  # Sample video blob (minimal valid MP4 header for testing)
  # This is a tiny valid MP4 file
  @test_video_blob <<
    0x00,
    0x00,
    0x00,
    0x20,
    0x66,
    0x74,
    0x79,
    0x70,
    0x69,
    0x73,
    0x6F,
    0x6D,
    0x00,
    0x00,
    0x02,
    0x00,
    0x69,
    0x73,
    0x6F,
    0x6D,
    0x69,
    0x73,
    0x6F,
    0x32,
    0x61,
    0x76,
    0x63,
    0x31,
    0x6D,
    0x70,
    0x34,
    0x31
  >>

  @test_thumbnail_blob <<0xFF, 0xD8, 0xFF, 0xE0>>

  describe "GET /api/v3/videos/:job_id/combined" do
    test "serves combined video successfully", %{conn: conn} do
      # Create a completed job with result blob
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      # Request the video
      conn = get(conn, ~p"/api/v3/videos/#{job.id}/combined")

      assert conn.status == 200
      assert List.first(get_resp_header(conn, "content-type")) =~ "video/mp4"
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert List.first(get_resp_header(conn, "etag")) != nil
      assert conn.resp_body == @test_video_blob
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/videos/99999/combined")

      assert json_response(conn, 404) == %{"error" => "Job not found"}
    end

    test "returns 404 when video not ready", %{conn: conn} do
      # Create a job without result
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/combined")

      assert json_response(conn, 404) == %{
               "error" => "Video not ready - job processing incomplete"
             }
    end

    test "returns 304 when ETag matches", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      # First request to get ETag
      conn1 = get(conn, ~p"/api/v3/videos/#{job.id}/combined")
      [etag] = get_resp_header(conn1, "etag")

      # Second request with If-None-Match
      conn2 =
        conn
        |> put_req_header("if-none-match", etag)
        |> get(~p"/api/v3/videos/#{job.id}/combined")

      assert conn2.status == 304
      assert conn2.resp_body == ""
    end

    test "supports Range requests for video scrubbing", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      # Request first 10 bytes
      conn =
        conn
        |> put_req_header("range", "bytes=0-9")
        |> get(~p"/api/v3/videos/#{job.id}/combined")

      assert conn.status == 206

      assert get_resp_header(conn, "content-range") == [
               "bytes 0-9/#{byte_size(@test_video_blob)}"
             ]

      assert byte_size(conn.resp_body) == 10
      assert conn.resp_body == binary_part(@test_video_blob, 0, 10)
    end

    test "handles suffix Range requests", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      # Request last 5 bytes
      conn =
        conn
        |> put_req_header("range", "bytes=-5")
        |> get(~p"/api/v3/videos/#{job.id}/combined")

      assert conn.status == 206
      total_size = byte_size(@test_video_blob)
      start_pos = total_size - 5

      assert get_resp_header(conn, "content-range") == [
               "bytes #{start_pos}-#{total_size - 1}/#{total_size}"
             ]

      assert byte_size(conn.resp_body) == 5
    end

    test "returns 416 for invalid Range", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      # Request out-of-bounds range
      conn =
        conn
        |> put_req_header("range", "bytes=9999-10000")
        |> get(~p"/api/v3/videos/#{job.id}/combined")

      assert conn.status == 416
      assert List.first(get_resp_header(conn, "content-range")) =~ "bytes */"
    end
  end

  describe "GET /api/v3/videos/:job_id/clips/:filename" do
    test "serves clip video successfully", %{conn: conn} do
      # Create a job and sub_job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      {:ok, sub_job} =
        %SubJob{}
        |> SubJob.changeset(%{
          job_id: job.id,
          provider_id: "test-provider-123",
          status: :completed,
          video_blob: @test_video_blob
        })
        |> Repo.insert()

      # Request the clip
      conn = get(conn, ~p"/api/v3/videos/#{job.id}/clips/#{sub_job.id}")

      assert conn.status == 200
      assert List.first(get_resp_header(conn, "content-type")) =~ "video/mp4"
      assert conn.resp_body == @test_video_blob
    end

    test "handles clip filename with .mp4 extension", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      {:ok, sub_job} =
        %SubJob{}
        |> SubJob.changeset(%{
          job_id: job.id,
          provider_id: "test-provider-123",
          status: :completed,
          video_blob: @test_video_blob
        })
        |> Repo.insert()

      # Request with .mp4 extension
      filename = "#{sub_job.id}.mp4"
      conn = get(conn, "/api/v3/videos/#{job.id}/clips/#{filename}")

      assert conn.status == 200
      assert conn.resp_body == @test_video_blob
    end

    test "handles clip filename with clip_ prefix", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      {:ok, sub_job} =
        %SubJob{}
        |> SubJob.changeset(%{
          job_id: job.id,
          provider_id: "test-provider-123",
          status: :completed,
          video_blob: @test_video_blob
        })
        |> Repo.insert()

      # Request with clip_ prefix
      filename = "clip_#{sub_job.id}.mp4"
      conn = get(conn, "/api/v3/videos/#{job.id}/clips/#{filename}")

      assert conn.status == 200
      assert conn.resp_body == @test_video_blob
    end

    test "returns 404 for non-existent clip", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      # Use a UUID that doesn't exist
      fake_uuid = Ecto.UUID.generate()
      conn = get(conn, ~p"/api/v3/videos/#{job.id}/clips/#{fake_uuid}")

      assert json_response(conn, 404) == %{"error" => "Clip not found"}
    end

    test "returns 404 when clip video not ready", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      {:ok, sub_job} =
        %SubJob{}
        |> SubJob.changeset(%{
          job_id: job.id,
          provider_id: "test-provider-123",
          status: :pending
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/clips/#{sub_job.id}")

      assert json_response(conn, 404) == %{"error" => "Clip video not ready"}
    end

    test "supports Range requests for clips", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      {:ok, sub_job} =
        %SubJob{}
        |> SubJob.changeset(%{
          job_id: job.id,
          provider_id: "test-provider-123",
          status: :completed,
          video_blob: @test_video_blob
        })
        |> Repo.insert()

      # Request with Range header
      conn =
        conn
        |> put_req_header("range", "bytes=0-9")
        |> get(~p"/api/v3/videos/#{job.id}/clips/#{sub_job.id}")

      assert conn.status == 206
      assert byte_size(conn.resp_body) == 10
    end
  end

  describe "GET /api/v3/videos/:job_id/thumbnail" do
    test "serves cached thumbnail from job progress", %{conn: conn} do
      # Create job with cached thumbnail (stored as Base64 in progress map)
      # Note: We store Base64-encoded thumbnails since JSONB doesn't support raw binary
      encoded_thumbnail = Base.encode64(@test_thumbnail_blob)

      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob,
          progress: %{"thumbnail" => encoded_thumbnail}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/thumbnail")

      assert conn.status == 200
      assert List.first(get_resp_header(conn, "content-type")) =~ "image/jpeg"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert conn.resp_body == @test_thumbnail_blob
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/videos/99999/thumbnail")

      assert json_response(conn, 404) == %{"error" => "Job not found"}
    end

    test "returns 404 when video not ready", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/thumbnail")

      assert json_response(conn, 404) == %{"error" => "Video not ready"}
    end

    test "supports ETag caching for thumbnails", %{conn: conn} do
      encoded_thumbnail = Base.encode64(@test_thumbnail_blob)

      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob,
          progress: %{"thumbnail" => encoded_thumbnail}
        })
        |> Repo.insert()

      # First request
      conn1 = get(conn, ~p"/api/v3/videos/#{job.id}/thumbnail")
      [etag] = get_resp_header(conn1, "etag")

      # Second request with If-None-Match
      conn2 =
        conn
        |> put_req_header("if-none-match", etag)
        |> get(~p"/api/v3/videos/#{job.id}/thumbnail")

      assert conn2.status == 304
      assert conn2.resp_body == ""
    end
  end

  describe "GET /api/v3/videos/:job_id/clips/:filename/thumbnail" do
    test "returns 404 for non-existent clip", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      fake_uuid = Ecto.UUID.generate()
      conn = get(conn, ~p"/api/v3/videos/#{job.id}/clips/#{fake_uuid}/thumbnail")

      assert json_response(conn, 404) == %{"error" => "Clip not found"}
    end

    test "returns 404 when clip video not ready", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{}
        })
        |> Repo.insert()

      {:ok, sub_job} =
        %SubJob{}
        |> SubJob.changeset(%{
          job_id: job.id,
          provider_id: "test-provider-123",
          status: :pending
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/clips/#{sub_job.id}/thumbnail")

      assert json_response(conn, 404) == %{"error" => "Clip video not ready"}
    end
  end

  describe "video serving optimization features" do
    test "sets proper filename in content-disposition header", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/combined")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/inline; filename="combined_#{job.id}\.mp4"/
    end

    test "sets content-length header for full video response", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/videos/#{job.id}/combined")

      [content_length] = get_resp_header(conn, "content-length")
      assert String.to_integer(content_length) == byte_size(@test_video_blob)
    end

    test "handles open-ended Range requests", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{},
          result: @test_video_blob
        })
        |> Repo.insert()

      # Request from byte 10 to end
      conn =
        conn
        |> put_req_header("range", "bytes=10-")
        |> get(~p"/api/v3/videos/#{job.id}/combined")

      assert conn.status == 206
      total_size = byte_size(@test_video_blob)

      assert get_resp_header(conn, "content-range") == [
               "bytes 10-#{total_size - 1}/#{total_size}"
             ]

      assert byte_size(conn.resp_body) == total_size - 10
    end
  end
end
