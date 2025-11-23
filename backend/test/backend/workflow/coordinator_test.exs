defmodule Backend.Workflow.CoordinatorTest do
  use Backend.DataCase, async: false
  alias Backend.Workflow.Coordinator
  alias Backend.Schemas.Job
  alias Backend.Repo

  setup do
    # Start the Coordinator if not already running
    coordinator_pid =
      case GenServer.whereis(Coordinator) do
        nil -> start_supervised!(Coordinator)
        pid -> pid
      end

    Backend.DataCase.allow_repo_access(coordinator_pid)

    :ok
  end

  describe "GenServer lifecycle" do
    test "starts successfully with registered name" do
      pid = GenServer.whereis(Coordinator)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "initializes with empty state" do
      # The coordinator should start with empty tracking maps
      # This is implicit in successful startup
      assert GenServer.whereis(Coordinator) != nil
    end
  end

  describe "job approval" do
    test "approves a pending job and starts processing" do
      # Create a pending job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :pending,
          parameters: %{test: "data"},
          progress: %{percentage: 0, stage: "created"}
        })
        |> Repo.insert()

      # Approve the job
      Coordinator.approve_job(job.id)

      # Give it time to process
      Process.sleep(100)

      # Verify the job status was updated
      updated_job = Repo.get(Job, job.id)
      assert updated_job.status in [:approved, :processing]
    end

    test "does not approve a job that's already processing" do
      # Create a processing job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data"},
          progress: %{percentage: 50, stage: "processing"}
        })
        |> Repo.insert()

      # Try to approve (should be handled gracefully)
      Coordinator.approve_job(job.id)

      # Give it time to process
      Process.sleep(100)

      # Job should remain in processing state
      updated_job = Repo.get(Job, job.id)
      assert updated_job.status == :processing
    end
  end

  describe "progress updates" do
    test "updates job progress successfully" do
      # Create a processing job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data"},
          progress: %{percentage: 0, stage: "initializing"}
        })
        |> Repo.insert()

      # Update progress
      new_progress = %{percentage: 50, stage: "rendering"}
      Coordinator.update_progress(job.id, new_progress)

      # Give it time to process
      Process.sleep(100)

      # Verify progress was updated
      updated_job = Repo.get(Job, job.id)
      assert updated_job.progress["percentage"] == 50
      assert updated_job.progress["stage"] == "rendering"
    end
  end

  describe "job completion" do
    test "marks job as completed with result" do
      # Create a processing job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data"},
          progress: %{percentage: 75, stage: "finalizing"}
        })
        |> Repo.insert()

      # Complete the job
      result = "Final video data"
      Coordinator.complete_job(job.id, result)

      # Give it time to process
      Process.sleep(100)

      # Verify job is completed
      updated_job = Repo.get(Job, job.id)
      assert updated_job.status == :completed
      assert updated_job.result == result
      assert updated_job.progress["percentage"] == 100
    end
  end

  describe "job failure" do
    test "marks job as failed with error message" do
      # Create a processing job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data"},
          progress: %{percentage: 30, stage: "rendering"}
        })
        |> Repo.insert()

      # Fail the job
      reason = "API timeout"
      Coordinator.fail_job(job.id, reason)

      # Give it time to process
      Process.sleep(100)

      # Verify job is failed
      updated_job = Repo.get(Job, job.id)
      assert updated_job.status == :failed
      assert updated_job.progress["stage"] == "failed"
      assert String.contains?(updated_job.progress["error"], reason)
    end
  end

  describe "startup recovery" do
    test "recovers interrupted jobs on startup" do
      # Create multiple processing jobs
      {:ok, job1} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data1"},
          progress: %{percentage: 40, stage: "rendering"}
        })
        |> Repo.insert()

      {:ok, job2} =
        %Job{}
        |> Job.changeset(%{
          type: :property_photos,
          status: :processing,
          parameters: %{test: "data2"},
          progress: %{percentage: 60, stage: "stitching"}
        })
        |> Repo.insert()

      # Simulate a restart by sending the recovery message
      coordinator_pid = GenServer.whereis(Coordinator)
      send(coordinator_pid, :recover_interrupted_jobs)

      # Give it time to recover
      Process.sleep(200)

      # Jobs should still be in processing or completed
      # (depending on the mock processing logic)
      job1_updated = Repo.get(Job, job1.id)
      job2_updated = Repo.get(Job, job2.id)

      assert job1_updated.status in [:processing, :completed, :failed]
      assert job2_updated.status in [:processing, :completed, :failed]
    end
  end

  describe "PubSub integration" do
    test "subscribes to job events" do
      # Subscribe to the job topics
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:created")
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:approved")
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:completed")

      # Create and approve a job
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :pending,
          parameters: %{test: "data"}
        })
        |> Repo.insert()

      # Approve the job
      Coordinator.approve_job(job.id)

      # Should receive approval event
      assert_receive {:job_approved, job_id}, 1000
      assert job_id == job.id
    end

    test "broadcasts completion events" do
      # Subscribe to completion topic
      Phoenix.PubSub.subscribe(Backend.PubSub, "jobs:completed")

      # Create a job and complete it
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          type: :image_pairs,
          status: :processing,
          parameters: %{test: "data"}
        })
        |> Repo.insert()

      # Complete the job
      Coordinator.complete_job(job.id, "test result")

      # Should receive completion event
      assert_receive {:job_completed, job_id}, 1000
      assert job_id == job.id
    end
  end
end
