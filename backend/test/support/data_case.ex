defmodule Backend.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Backend.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backend.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Backend.DataCase
    end
  end

  setup tags do
    Backend.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Backend.Repo, shared: not tags[:async])
    Process.put(:sandbox_owner, owner)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      Process.delete(:sandbox_owner)
    end)
  end

  @doc """
  Allows a background process (e.g., Workflow Coordinator) to use the shared sandbox connection.
  """
  def allow_repo_access(pid) when is_pid(pid) do
    case Process.get(:sandbox_owner) do
      nil ->
        :ok

      owner ->
        Ecto.Adapters.SQL.Sandbox.allow(Backend.Repo, owner, pid)
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
