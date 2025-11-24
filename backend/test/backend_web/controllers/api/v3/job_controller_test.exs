defmodule BackendWeb.Api.V3.JobControllerTest do
  use BackendWeb.ConnCase, async: false
  alias Backend.Schemas.Job
  alias Backend.Repo
  alias Backend.Workflow.Coordinator

  setup do
    # Ensure Coordinator is running
    coordinator_pid =
      case GenServer.whereis(Coordinator) do
        nil -> start_supervised!(Coordinator)
        pid -> pid
      end

    Backend.DataCase.allow_repo_access(coordinator_pid)

    :ok
  end

  describe "POST /api/v3/jobs/:id/approve" do
    test "approves a pending job successfully", %{conn: conn} do
      # Create a pending job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :pending,
          parameters: %{test: "data"},
          progress: %{percentage: 0, stage: "created"},
          video_name: "Test Video",
          estimated_cost: 5.0
        })
        |> Repo.insert()

      # Approve the job
      conn = post(conn, ~p"/api/v3/jobs/#{job.id}/approve")

      assert json_response(conn, 200) == %{
               "message" => "Job approved successfully",
               "job_id" => job.id,
               "status" => "approved"
             }

      # Verify the job was updated
      Process.sleep(100)
      updated_job = Repo.get(Job, job.id)
      assert updated_job.status in [:approved, :processing]
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      # Try to approve a non-existent job
      conn = post(conn, ~p"/api/v3/jobs/99999/approve")

      assert json_response(conn, 404) == %{
               "error" => "Job not found",
               "job_id" => "99999"
             }
    end

    test "returns 422 for job not in pending state", %{conn: conn} do
      # Create a processing job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data"},
          video_name: "Processing Video",
          estimated_cost: 5.0
        })
        |> Repo.insert()

      # Try to approve it
      conn = post(conn, ~p"/api/v3/jobs/#{job.id}/approve")

      response = json_response(conn, 422)
      assert response["error"] == "Job cannot be approved"
      assert response["job_id"] == job.id
      assert response["current_status"] == "processing"
    end

    test "returns 422 for completed job", %{conn: conn} do
      # Create a completed job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{test: "data"},
          result: "final video",
          video_name: "Completed Video",
          estimated_cost: 5.0
        })
        |> Repo.insert()

      # Try to approve it
      conn = post(conn, ~p"/api/v3/jobs/#{job.id}/approve")

      response = json_response(conn, 422)
      assert response["error"] == "Job cannot be approved"
      assert response["current_status"] == "completed"
    end
  end

  describe "GET /api/v3/jobs/:id" do
    test "returns job details for existing job", %{conn: conn} do
      # Create a job with detailed information
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :property_photos,
          status: :processing,
          parameters: %{"campaign_id" => "test-123", "scenes" => ["scene1", "scene2"]},
          storyboard: %{"scenes" => [%{"id" => 1, "description" => "Opening shot"}]},
          progress: %{percentage: 45, stage: "rendering"},
          video_name: "Campaign Video",
          estimated_cost: 12.34
        })
        |> Repo.insert()

      # Get job details
      conn = get(conn, ~p"/api/v3/jobs/#{job.id}")

      response = json_response(conn, 200)
      assert response["job_id"] == job.id
      assert response["type"] == "property_photos"
      assert response["status"] == "processing"
      assert response["video_name"] == "Campaign Video"
      assert response["estimated_cost"] == 12.34
      assert response["costs"]["estimated"] == 12.34
      assert response["progress_percentage"] == 45
      assert response["current_stage"] == "rendering"
      assert response["parameters"]["campaign_id"] == "test-123"
      assert is_map(response["storyboard"])
    end

    test "returns 404 for non-existent job", %{conn: conn} do
      conn = get(conn, ~p"/api/v3/jobs/99999")

      assert json_response(conn, 404) == %{
               "error" => "Job not found",
               "job_id" => "99999"
             }
    end

    test "returns correct progress for pending job", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :pending,
          parameters: %{test: "data"},
          video_name: "Pending Video",
          estimated_cost: 3.21
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/jobs/#{job.id}")

      response = json_response(conn, 200)
      assert response["status"] == "pending"
      # No progress set, should default to 0
      assert response["progress_percentage"] == 0
    end

    test "returns correct progress for completed job", %{conn: conn} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :completed,
          parameters: %{test: "data"},
          progress: %{percentage: 100, stage: "completed"},
          result: "final video data",
          video_name: "Finished Video",
          estimated_cost: 8.75
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/jobs/#{job.id}")

      response = json_response(conn, 200)
      assert response["status"] == "completed"
      assert response["progress_percentage"] == 100
      assert response["current_stage"] == "completed"
    end

    test "handles job with string keys in progress map", %{conn: conn} do
      # Some jobs might have progress with string keys instead of atom keys
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{},
          progress: %{"percentage" => 60, "stage" => "stitching"},
          video_name: "String Key Video",
          estimated_cost: 4.2
        })
        |> Repo.insert()

      conn = get(conn, ~p"/api/v3/jobs/#{job.id}")

      response = json_response(conn, 200)
      assert response["progress_percentage"] == 60
      assert response["current_stage"] == "stitching"
    end
  end

  describe "GET /api/v3/generated-videos" do
    test "lists completed jobs that have video results", %{conn: conn} do
      job_a =
        insert_job(%{
          status: :completed,
          result: "video-a",
          parameters: %{"campaign_id" => "camp-1", "client_id" => "client-1"}
        })

      job_b =
        insert_job(%{
          status: :completed,
          result: "video-b",
          parameters: %{"campaign_id" => "camp-2", "client_id" => "client-2"}
        })

      _skipped_job =
        insert_job(%{
          status: :processing,
          result: nil,
          parameters: %{"campaign_id" => "camp-1"}
        })

      response =
        conn
        |> get(~p"/api/v3/generated-videos")
        |> json_response(200)

      returned_ids = Enum.map(response["data"], & &1["job_id"])
      assert Enum.sort(returned_ids) == Enum.sort([job_a.id, job_b.id])
    end

    test "filters by job_id parameter", %{conn: conn} do
      job_a =
        insert_job(%{
          status: :completed,
          result: "video-a",
          parameters: %{"campaign_id" => "camp-1", "client_id" => "client-1"}
        })

      _job_b =
        insert_job(%{
          status: :completed,
          result: "video-b",
          parameters: %{"campaign_id" => "camp-2", "client_id" => "client-2"}
        })

      response =
        conn
        |> get(~p"/api/v3/generated-videos", %{job_id: job_a.id})
        |> json_response(200)

      assert Enum.map(response["data"], & &1["job_id"]) == [job_a.id]
    end

    test "filters by campaign_id and client_id parameters", %{conn: conn} do
      job =
        insert_job(%{
          status: :completed,
          result: "video-a",
          parameters: %{"campaign_id" => "camp-3", "client_id" => "client-9"}
        })

      _other_job =
        insert_job(%{
          status: :completed,
          result: "video-b",
          parameters: %{"campaign_id" => "camp-1", "client_id" => "client-1"}
        })

      response =
        conn
        |> get(~p"/api/v3/generated-videos", %{campaign_id: "camp-3", client_id: "client-9"})
        |> json_response(200)

      assert Enum.map(response["data"], & &1["job_id"]) == [job.id]
    end

    test "returns storyboard data for thumbnail generation", %{conn: conn} do
      storyboard = %{
        "scenes" => [
          %{"id" => "scene-1", "asset_ids" => ["asset-123"], "title" => "Front of house"}
        ]
      }

      job =
        insert_job(%{
          status: :completed,
          result: "video-thumb",
          storyboard: storyboard
        })

      response =
        conn
        |> get(~p"/api/v3/generated-videos", %{job_id: job.id})
        |> json_response(200)

      [payload] = response["data"]
      assert payload["storyboard"] == storyboard
    end
  end

  describe "job approval workflow integration" do
    test "approved job triggers coordinator processing", %{conn: conn} do
      # Subscribe to PubSub to verify events
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:approved")

      # Create a pending job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :pending,
          parameters: %{test: "integration"},
          video_name: "Approval Video",
          estimated_cost: 6.5
        })
        |> Repo.insert()

      # Approve via API
      conn = post(conn, ~p"/api/v3/jobs/#{job.id}/approve")
      assert json_response(conn, 200)["status"] == "approved"

      # Wait for PubSub event
      assert_receive {:job_approved, job_id}, 1000
      assert job_id == job.id

      # Verify job is being processed
      Process.sleep(200)
      updated_job = Repo.get(Job, job.id)
      assert updated_job.status in [:approved, :processing]
    end
  end

  defp insert_job(attrs) do
    base_attrs = %{
      type: :image_pairs,
      status: :pending,
      parameters: %{},
      progress: %{},
      storyboard: %{},
      video_name: "Generated Video",
      estimated_cost: 7.0
    }

    %Job{}
    |> Job.changeset(Map.merge(base_attrs, attrs))
    |> Repo.insert!()
  end
end
