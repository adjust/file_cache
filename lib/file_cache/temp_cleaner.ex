defmodule FileCache.TempCleaner do
  use FileCache.Cleaner

  alias FileCache.Config
  alias FileCache.Temp
  alias FileCache.Utils

  @impl true
  def cleanup(%S{cache_name: cache_name} = s) do
    cache_name
    |> Temp.wildcard()
    |> maybe_remove_files(cache_name)
  end

  defp maybe_remove_files(paths, cache_name) do
    Enum.each(paths, fn path ->
      with true <- file_to_remove?(path, cache_name),
           {:error, err} <- Utils.rm_ignore_missing(path) do
        Logger.error("Failed to remove temp file for cache #{cache_name}: #{err}")
      end
    end)
  end

  defp file_to_remove?(path, cache_name) do
    try do
      Temp.parse_filepath(path)
    rescue
      e ->
        Logger.error("Failed to parse temp file for cache #{cache_name}: #{Exception.message(e)}")
    else
      %{pid: pid} ->
        not Process.alive?(pid)
    end
  end
end
