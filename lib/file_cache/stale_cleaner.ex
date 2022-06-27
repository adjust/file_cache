defmodule FileCache.StaleCleaner do
  use FileCache.Cleaner

  alias FileCache.Config
  alias FileCache.Perm
  alias FileCache.Common
  alias FileCache.Utils

  @impl true
  def name(%{cache_name: cache_name}), do: make_name(cache_name, create: true)
  def name(cache_name) when is_atom(cache_name), do: make_name(cache_name)

  defp make_name(cache_name, opts \\ []) do
    Common.cache_process_name(__MODULE__, cache_name, opts)
  end

  def schedule_file_removal(file_or_files, cache_name) do
    GenServer.cast(make_name(cache_name), {:remove_files, file_or_files})
  end

  def schedule_clean(id, cache_name) do
    GenServer.cast(make_name(cache_name), {:clean_file, id})
  end

  # FIXME: GenServer usage leaks here: provide Cleaner callback?
  # e.g. Module.request/1
  @impl true
  def handle_cast({:remove_files, file_or_files}, %{cache_name: cache_name} = s) do
    file_or_files
    |> List.wrap()
    |> maybe_remove_files(cache_name)

    s
  end

  @impl true
  def handle_cast({:clean_file, id}, s) do
    # TODO: what?
    # id
    # |> Perm.find_for_id(s.cache_name)
    # |> rm_file(s.cache_name)

    {:noreply, s}
  end

  @impl true
  def cleanup(%{cache_name: cache_name} = s) do
    cache_name
    |> Perm.wildcard()
    |> maybe_remove_files(cache_name)
  end

  defp maybe_remove_files(paths, cache_name) do
    now = Utils.system_time()

    Enum.each(paths, fn path ->
      with true <- file_to_remove?(path, now, cache_name),
           {:error, err} <- Utils.rm_ignore_missing(path) do
        Logger.error("Failed to remove file for cache #{cache_name}: #{err}")
      end
    end)
  end

  defp file_to_remove?(path, now, cache_name) do
    try do
      Perm.parse_filepath(path)
    rescue
      e ->
        Logger.error("Failed to parse file for cache #{cache_name}: #{Exception.message(e)}")
    else
      %{expires_at: timestamp} ->
        timestamp > now
    end
  end
end
