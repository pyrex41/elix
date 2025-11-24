defmodule Backend.Services.AudioSegmentStore do
  @moduledoc """
  In-memory cache for short-lived audio segments so we can expose
  continuation clips over HTTP and reuse them across MusicGen calls.
  """
  use GenServer
  require Logger

  @table :audio_segment_store
  @cleanup_interval :timer.minutes(5)
  @default_ttl :timer.minutes(30)

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Stores an audio blob and returns a lookup token.

  ## Options
    * `:ttl` - time-to-live in milliseconds (default 30 minutes)
  """
  def store(blob, opts \\ []) when is_binary(blob) and byte_size(blob) > 0 do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    token = generate_token()

    case GenServer.call(__MODULE__, {:store, token, blob, ttl}) do
      :ok -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :store_not_ready}
  end

  @doc """
  Fetches an audio blob by token.
  """
  def fetch(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:fetch, token})
  catch
    :exit, {:noproc, _} ->
      {:error, :store_not_ready}
  end

  # Server callbacks

  @impl true
  def init(_) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:set, :protected, read_concurrency: true])

        table_id ->
          table_id
      end

    schedule_cleanup()
    {:ok, table}
  end

  @impl true
  def handle_call({:store, token, blob, ttl}, _from, table) do
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(table, {token, blob, expires_at})
    {:reply, :ok, table}
  end

  @impl true
  def handle_call({:fetch, token}, _from, table) do
    reply =
      case :ets.lookup(table, token) do
        [{^token, blob, expires_at}] ->
          if expires_at > System.monotonic_time(:millisecond) do
            {:ok, blob}
          else
            :ets.delete(table, token)
            {:error, :expired}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, table}
  end

  @impl true
  def handle_info(:cleanup, table) do
    cleanup_expired(table)
    schedule_cleanup()
    {:noreply, table}
  end

  defp generate_token do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired(table) do
    now = System.monotonic_time(:millisecond)

    match_spec = [
      {
        {:"$1", :"$2", :"$3"},
        [
          {:<, :"$3", now}
        ],
        [true]
      }
    ]

    :ets.select_delete(table, match_spec)
  rescue
    e ->
      Logger.warning("[AudioSegmentStore] Cleanup failed: #{inspect(e)}")
  end
end
