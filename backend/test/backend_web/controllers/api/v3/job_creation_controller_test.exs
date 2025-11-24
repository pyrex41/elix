defmodule BackendWeb.Api.V3.JobCreationControllerTest do
  use BackendWeb.ConnCase, async: false
  alias Backend.Schemas.{Campaign, Client, Asset, Job}
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

    # Create a test client
    {:ok, client} =
      %Client{}
      |> Client.changeset(%{
        name: "Test Client",
        email: "test@example.com"
      })
      |> Repo.insert()

    # Create a test campaign
    {:ok, campaign} =
      %Campaign{}
      |> Campaign.changeset(%{
        name: "Test Campaign",
        brief: "A test campaign for video generation with compelling brand narrative.",
        client_id: client.id
      })
      |> Repo.insert()

    # Create test assets for the campaign
    {:ok, asset1} =
      %Asset{}
      |> Asset.changeset(%{
        type: :image,
        blob_data: <<1, 2, 3, 4>>,
        campaign_id: campaign.id,
        metadata: %{"width" => 1920, "height" => 1080}
      })
      |> Repo.insert()

    {:ok, asset2} =
      %Asset{}
      |> Asset.changeset(%{
        type: :image,
        blob_data: <<5, 6, 7, 8>>,
        campaign_id: campaign.id,
        metadata: %{"width" => 1920, "height" => 1080}
      })
      |> Repo.insert()

    %{
      client: client,
      campaign: campaign,
      assets: [asset1, asset2]
    }
  end

  describe "POST /api/v3/jobs/from-image-pairs" do
    test "creates job successfully with valid campaign_id", %{conn: conn, campaign: campaign} do
      # Subscribe to PubSub to verify job creation event
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:created")

      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => campaign.id
        })

      response = json_response(conn, 201)
      assert response["status"] == "pending"
      assert response["type"] == "image_pairs"
      assert is_integer(response["job_id"])
      assert response["scene_count"] > 0
      assert response["message"] == "Job created successfully"
      assert response["video_name"] == "#{campaign.name} 1"
      assert is_float(response["estimated_cost"])
      assert response["costs"]["estimated"] == response["estimated_cost"]
      assert response["costs"]["currency"] == "USD"

      # Verify job was created in database
      job = Repo.get(Job, response["job_id"])
      assert job.type == :image_pairs
      assert job.status == :pending
      assert is_map(job.storyboard)
      assert is_list(job.storyboard["scenes"])
      assert_in_delta job.parameters["estimated_cost"], response["estimated_cost"], 0.0001
      assert job.progress["costs"]["estimated"] == response["estimated_cost"]
      assert job.video_name == "#{campaign.name} 1"

      # Verify sub_jobs were created
      sub_jobs = Repo.all(Ecto.assoc(job, :sub_jobs))
      assert length(sub_jobs) == response["scene_count"]
      assert Enum.all?(sub_jobs, &(&1.status == :pending))

      # Verify PubSub event was broadcast
      assert_receive {:job_created, job_id}, 1000
      assert job_id == response["job_id"]
    end

    test "increments video name per campaign", %{conn: conn, campaign: campaign} do
      post(conn, ~p"/api/v3/jobs/from-image-pairs", %{"campaign_id" => campaign.id})

      second_conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{"campaign_id" => campaign.id})

      response = json_response(second_conn, 201)
      assert response["video_name"] == "#{campaign.name} 2"
    end

    test "creates job with additional parameters", %{conn: conn, campaign: campaign} do
      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => campaign.id,
          "parameters" => %{
            "style" => "modern",
            "music" => "upbeat"
          }
        })

      response = json_response(conn, 201)
      job = Repo.get(Job, response["job_id"])
      assert job.parameters["style"] == "modern"
      assert job.parameters["music"] == "upbeat"
    end

    test "returns 400 when campaign_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v3/jobs/from-image-pairs", %{})

      assert json_response(conn, 400) == %{
               "error" => "campaign_id is required"
             }
    end

    test "returns 404 when campaign does not exist", %{conn: conn} do
      fake_uuid = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => fake_uuid
        })

      assert json_response(conn, 404) == %{
               "error" => "Campaign not found"
             }
    end

    test "returns 400 when campaign has no assets", %{conn: conn, client: client} do
      # Create a campaign with no assets
      {:ok, empty_campaign} =
        %Campaign{}
        |> Campaign.changeset(%{
          name: "Empty Campaign",
          brief: "No assets here",
          client_id: client.id
        })
        |> Repo.insert()

      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => empty_campaign.id
        })

      assert json_response(conn, 400) == %{
               "error" => "Campaign has no assets"
             }
    end
  end

  describe "POST /api/v3/jobs/from-property-photos" do
    test "creates job successfully with valid campaign_id", %{conn: conn, campaign: campaign} do
      # Subscribe to PubSub to verify job creation event
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:created")

      conn =
        post(conn, ~p"/api/v3/jobs/from-property-photos", %{
          "campaign_id" => campaign.id,
          "property_types" => ["exterior", "interior", "kitchen"]
        })

      response = json_response(conn, 201)
      assert response["status"] == "pending"
      assert response["type"] == "property_photos"
      assert is_integer(response["job_id"])
      assert response["scene_count"] > 0
      assert response["property_types"] == ["exterior", "interior", "kitchen"]
      assert response["message"] == "Job created successfully"
      assert response["video_name"] == "#{campaign.name} 1"
      assert is_float(response["estimated_cost"])

      # Verify job was created in database
      job = Repo.get(Job, response["job_id"])
      assert job.type == :property_photos
      assert job.status == :pending
      assert job.parameters["property_types"] == ["exterior", "interior", "kitchen"]
      assert job.video_name == "#{campaign.name} 1"
      assert_in_delta job.parameters["estimated_cost"], response["estimated_cost"], 0.0001

      # Verify all scenes have valid scene_types
      scenes = job.storyboard["scenes"]
      scene_types = Enum.map(scenes, & &1["scene_type"])
      assert Enum.all?(scene_types, &(&1 in ["exterior", "interior", "kitchen"]))

      # Verify sub_jobs were created
      sub_jobs = Repo.all(Ecto.assoc(job, :sub_jobs))
      assert length(sub_jobs) == response["scene_count"]

      # Verify PubSub event was broadcast
      assert_receive {:job_created, job_id}, 1000
      assert job_id == response["job_id"]
    end

    test "uses default property types when not specified", %{conn: conn, campaign: campaign} do
      conn =
        post(conn, ~p"/api/v3/jobs/from-property-photos", %{
          "campaign_id" => campaign.id
        })

      response = json_response(conn, 201)
      assert is_list(response["property_types"])
      assert length(response["property_types"]) > 0
    end

    test "validates scene types match allowed property types", %{conn: conn, campaign: campaign} do
      # This test verifies that the scene types generated match the allowed types
      conn =
        post(conn, ~p"/api/v3/jobs/from-property-photos", %{
          "campaign_id" => campaign.id,
          "property_types" => ["bedroom", "bathroom"]
        })

      response = json_response(conn, 201)
      job = Repo.get(Job, response["job_id"])

      # All generated scenes should have scene_type in the allowed list
      scenes = job.storyboard["scenes"]
      scene_types = Enum.map(scenes, & &1["scene_type"])
      assert Enum.all?(scene_types, &(&1 in ["bedroom", "bathroom"]))
    end

    test "returns 400 when campaign_id is missing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v3/jobs/from-property-photos", %{
          "property_types" => ["exterior"]
        })

      assert json_response(conn, 400) == %{
               "error" => "campaign_id is required"
             }
    end

    test "returns 404 when campaign does not exist", %{conn: conn} do
      fake_uuid = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/v3/jobs/from-property-photos", %{
          "campaign_id" => fake_uuid,
          "property_types" => ["exterior"]
        })

      assert json_response(conn, 404) == %{
               "error" => "Campaign not found"
             }
    end
  end

  describe "job creation integration" do
    test "job creation workflow end-to-end", %{conn: conn, campaign: campaign} do
      # Create job
      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => campaign.id
        })

      response = json_response(conn, 201)
      job_id = response["job_id"]

      # Verify job can be retrieved
      conn = get(build_conn(), ~p"/api/v3/jobs/#{job_id}")
      job_response = json_response(conn, 200)
      assert job_response["job_id"] == job_id
      assert job_response["status"] == "pending"

      # Verify job can be approved
      conn = post(build_conn(), ~p"/api/v3/jobs/#{job_id}/approve")
      approve_response = json_response(conn, 200)
      assert approve_response["job_id"] == job_id
    end

    test "multiple jobs can be created for same campaign", %{conn: conn, campaign: campaign} do
      # Create first job
      conn1 =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => campaign.id
        })

      response1 = json_response(conn1, 201)

      # Create second job
      conn2 =
        post(build_conn(), ~p"/api/v3/jobs/from-property-photos", %{
          "campaign_id" => campaign.id
        })

      response2 = json_response(conn2, 201)

      # Both jobs should be created successfully
      assert response1["job_id"] != response2["job_id"]
      assert response1["type"] == "image_pairs"
      assert response2["type"] == "property_photos"

      # Both jobs should exist in database
      job1 = Repo.get(Job, response1["job_id"])
      job2 = Repo.get(Job, response2["job_id"])
      assert job1 != nil
      assert job2 != nil
    end
  end

  describe "storyboard structure" do
    test "storyboard contains valid scene data", %{conn: conn, campaign: campaign} do
      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => campaign.id
        })

      response = json_response(conn, 201)
      job = Repo.get(Job, response["job_id"])

      storyboard = job.storyboard
      assert is_map(storyboard)
      assert is_list(storyboard["scenes"])
      assert is_number(storyboard["total_duration"])

      # Verify each scene has required fields
      Enum.each(storyboard["scenes"], fn scene ->
        assert is_binary(scene["title"])
        assert is_binary(scene["description"])
        assert is_number(scene["duration"])
        assert scene["duration"] > 0
      end)
    end

    test "total_duration matches sum of scene durations", %{conn: conn, campaign: campaign} do
      conn =
        post(conn, ~p"/api/v3/jobs/from-image-pairs", %{
          "campaign_id" => campaign.id
        })

      response = json_response(conn, 201)
      job = Repo.get(Job, response["job_id"])

      scenes = job.storyboard["scenes"]
      total_duration = job.storyboard["total_duration"]

      calculated_total =
        Enum.reduce(scenes, 0, fn scene, acc ->
          acc + scene["duration"]
        end)

      assert total_duration == calculated_total
    end
  end
end
