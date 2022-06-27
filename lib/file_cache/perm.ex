defmodule FileCache.Perm do
  alias FileCache.Config
  alias FileCache.Common
  alias FileCache.Utils

  def find_for_id(id, cache_name, opts \\ []) do
    # OPT: return_stale: true
    # 1. list all files containing id sorted by timestamp
    # 2. Remove the stale ones (async)
    # 3. Return relevant one
  end

  def file_path(id, cache_name, opts \\ []) do
    ttl = Access.get(opts, :ttl) || Config.get(cache_name, :ttl)

    expiration_timestamp =
      System.os_time()
      |> System.convert_time_unit(:system, :millisecond)
      |> Kernel.+(ttl)

    filename = "#{filename_prefix()}_#{expiration_timestamp}_#{id}"

    Path.join(full_dir_path(cache_name), filename)
  end

  def wildcard(cache_name) do
    cache_name
    |> full_dir_path()
    |> Path.join("#{filename_prefix()}")
    |> Utils.wildcard_suffix()
  end

  def full_dir_path(cache_name) do
    config = Config.get(cache_name)

    Path.join([
      config.dir,
      Common.calculate_namespace(config.namespace),
      cache_name
    ])
  end

  def parse_filepath(path) when is_binary(path) do
    filename = Path.basename(path)
    dirname = Path.dirname(path)

    # NOTE: note the `parts: 3`: because ID can contain underscores, we put it specifically in the end
    # to avoid splitting it by accident
    [prefix, expiration_timestamp_str, id] = String.split(filename, "_", parts: 3)

    if prefix != filename_prefix() do
      raise ArgumentError, message: "Incorrect filepath prefix: #{path}"
    end

    expiration_timestamp =
      try do
        String.to_integer(expiration_timestamp_str)
      rescue
        ArgumentError ->
          raise ArgumentError, message: "Incorrect filepath timestamp: #{path}"
      end

    %{
      dir: dirname,
      expires_at: expiration_timestamp,
      id: id
    }
  end

  def filename_prefix do
    "perm_file_cache"
  end
end
