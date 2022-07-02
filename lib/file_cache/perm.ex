defmodule FileCache.Perm do
  @moduledoc false

  require Logger

  @sep "$"

  alias FileCache.Config
  alias FileCache.Common
  alias FileCache.Utils
  alias FileCache.StaleCleaner

  def setup(opts), do: File.mkdir_p!(full_dir_path(opts[:cache]))

  def find(id, cache_name, opts \\ []) when is_binary(id) do
    # NOTE: due to the way information is encoded into filenames,
    # we might wildcard files with ids that have suffix as the id passed as arg.
    # (e.g. ..._underscored_long_id and ..._long_id)
    # Therefore, we need to check that it's exactly the one we're interested in
    #
    # Solving it properly (without id extensive check below) would improve lookup operation performance
    #
    # One way to solve it is that we can split cache file basename completely and not into N parts (see `parse_filename`
    # code), but that would consume more resources on rebuilding ids back
    #
    # So for the time being, we are finding (and cleaning) *all* files with the suffix of `id`

    result = find_all(id, cache_name, opts)[id]
    result && result[:path]
  end

  def find_all(cache_name), do: find_all(cache_name, [])
  def find_all(cache_name, opts), do: find_all(:all, cache_name, opts)

  def find_all(id, cache_name, opts) do
    # NOTE: the obvious question is: why map as acc? shouldn't we have files for only a single id?
    # The problem is that we can wildcard files with other ids if arg id is their suffix
    # (e.g. ..._underscored_long_id and ..._long_id)

    now = Utils.system_time()
    {sync_clean?, _opts} = Keyword.pop(opts, :sync_clean, false)

    cache_name
    |> wildcard(id)
    |> Enum.reduce(%{}, fn path, acc ->
      with {:ok, this} <- parse_filepath(path, cache_name) do
        exp = this.expires_at
        last = Map.get(acc, this.id)

        # NOTE: since we're going through files here anyway, we might as well notify
        # StaleCleaner about files that are stale to reduce amount of total work
        if exp > now and (is_nil(last) or last.expires_at < exp) do
          # TODO: PERF: we're constructing process name atom each time we're scheduling file removal:
          # optimize it by using PID?

          last && remove_file(last.path, cache_name, sync_clean?)
          Map.put(acc, this.id, Map.put(this, :path, path))
        else
          remove_file(path, cache_name, sync_clean?)
          acc
        end
      else
        {:error, _} ->
          Common.maybe_remove_unknown_file(path, cache_name)
          acc
      end
    end)
  end

  def delete(id, cache_name, _opts) do
    cache_name
    |> wildcard(id)
    |> Enum.each(fn path ->
      with {:ok, info} <- parse_filepath(path, cache_name),
           true <- id == :all or is_nil(id) or info.id == id do
        remove_file(path, cache_name, true)
      end
    end)
  end

  def file_path(id, cache_name, opts \\ []) do
    ttl = Access.get(opts, :ttl) || Config.get(cache_name, :ttl)

    expiration_timestamp = Utils.system_time() + ttl

    filename = "#{filename_prefix()}#{@sep}#{expiration_timestamp}#{@sep}#{id}"

    Path.join(full_dir_path(cache_name), filename)
  end

  def wildcard(cache_name, id \\ nil) do
    cache_name
    |> full_dir_path()
    |> Path.join("#{filename_prefix()}#{@sep}")
    |> Utils.escape_path_for_wildcard()
    |> case do
      asis when is_nil(id) or id == :all ->
        Utils.wildcard_suffix(asis)

      left ->
        Path.wildcard("#{left}*$#{Utils.escape_path_for_wildcard(id)}")
    end
  end

  def full_dir_path(cache_name) do
    config = Config.get(cache_name)

    Path.join([
      config.dir,
      Common.calculate_namespace(config.namespace),
      "#{cache_name}"
    ])
  end

  def parse_filepath(path, cache_name) when is_binary(path) do
    filename = Path.basename(path)
    # dirname = Path.dirname(path)

    # NOTE: note the `parts: 3`: because ID can contain underscores, we put it specifically in the end
    # to avoid splitting it by accident

    with [prefix, expiration_timestamp_str, id] <- String.split(filename, @sep, parts: 3),
         {:ok, _prefix} <- parse_prefix(prefix),
         {:ok, expiration_timestamp} <- parse_timestamp(expiration_timestamp_str) do
      {:ok,
       %{
         # dir: dirname,
         expires_at: expiration_timestamp,
         id: id
       }}
    else
      parts when is_list(parts) ->
        Common.log(:error, cache_name, "Incorrect filepath format: #{path}")
        {:error, :bad_format}

      {:error, :bad_prefix} = e ->
        Common.log(:error, cache_name, "Incorrect filepath prefix: #{path}")
        e

      {:error, :bad_timestamp} = e ->
        Common.log(:error, cache_name, "Incorrect filepath timestamp: #{path}")
        e
    end
  end

  def filename_prefix do
    "perm-file-cache"
  end

  def remove_file(path, cache_name, sync?)

  def remove_file(path, cache_name, true) do
    with {:error, err} <- Utils.rm_ignore_missing(path) do
      Logger.error("Failed to remove file for cache #{cache_name}: #{err}")
    end
  end

  def remove_file(path, cache_name, false) do
    StaleCleaner.schedule_file_removal(path, cache_name)
  end

  defp parse_prefix(prefix) do
    case prefix == filename_prefix() do
      true -> {:ok, prefix}
      false -> {:error, :bad_prefix}
    end
  end

  defp parse_timestamp(timestamp_str) do
    {:ok, String.to_integer(timestamp_str)}
  rescue
    ArgumentError ->
      {:error, :bad_timestamp}
  end
end
