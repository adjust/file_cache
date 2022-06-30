defmodule FileCache.StaleCleaner do
  @moduledoc false

  use FileCache.Cleaner

  alias FileCache.Config
  alias FileCache.Perm
  alias FileCache.Common

  @impl true
  def name(cache_name) when is_atom(cache_name), do: make_name(cache_name)

  def name(opts) do
    cache_name = opts[:cache] || raise RuntimeError, message: "Wrong init options: #{opts}"
    make_name(cache_name, create: true)
  end

  defp make_name(cache_name, opts \\ []) when is_atom(cache_name) do
    Common.cache_process_name(__MODULE__, cache_name, opts)
  end

  def schedule_file_removal(file_or_files, cache_name) do
    GenServer.cast(make_name(cache_name), {:remove_files, file_or_files})
  end

  def schedule_clean(id, cache_name) do
    GenServer.cast(make_name(cache_name), {:clean, id})
  end

  # FIXME: GenServer usage leaks here: provide Cleaner callback?
  # e.g. Module.request/1
  @impl true
  def handle_cast({:remove_files, file_or_files}, %{cache: cache_name} = s) do
    # NOTE: we're not checking the files passed here, since this message is sent only from `Perm`s `find_all`

    file_or_files
    |> List.wrap()
    |> Enum.each(&Perm.remove_file(&1, cache_name, true))

    {:noreply, s}
  end

  # NOTE: proper cleaning is done as a side-effect of finding the most up-to-date one
  @impl true
  def handle_cast({:clean, id}, s) do
    _ = Perm.find_all(id, s.cache, sync_clean: true)

    {:noreply, s}
  end

  @impl true
  def cleanup(s) do
    _ = Perm.find_all(s.cache, sync_clean: true)
  end
end
