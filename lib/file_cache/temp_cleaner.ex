defmodule FileCache.TempCleaner do
  @moduledoc false

  use FileCache.Cleaner, kind: :temp

  alias FileCache.Config
  alias FileCache.Temp
  alias FileCache.Common
  alias FileCache.Utils

  @impl true
  def cleanup(%S{cache: cache_name}) do
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
    case Temp.parse_filepath(path, cache_name) do
      {:ok, %{pid: pid}} ->
        not Process.alive?(pid)

      {:error, _} ->
        Common.maybe_remove_unknown_file(path, cache_name)
        false
    end
  end
end
