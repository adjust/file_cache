defmodule FileCache.Temp do
  alias FileCache.Config
  alias FileCache.Common
  alias FileCache.Utils

  # File path format:
  # /temp_dir/namespace.../cache_name/tmp_file_cache_<OWNER_PID>_<UNIQUE_NUM>_<ID>

  def file_path(id, cache_name, opts \\ []) do
    owner = Access.get(opts, :owner, self())

    filename =
      "#{filename_prefix()}_#{Utils.pid_to_string(owner)}_#{:erlang.unique_integer()}_#{id}"

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
      config.temp_dir,
      Common.calculate_namespace(config.temp_namespace),
      cache_name
    ])
  end

  def parse_filepath(path) when is_binary(path) do
    filename = Path.basename(path)
    dirname = Path.dirname(path)

    # NOTE: note the `parts: 4`: because ID can contain underscores, we put it specifically in the end
    # to avoid splitting it by accident
    [prefix, pid_str, _uniq_id, id] = String.split(filename, "_", parts: 4)

    if prefix != filename_prefix() do
      raise ArgumentError, message: "Incorrect temp filepath prefix: #{path}"
    end

    pid =
      try do
        :erlang.list_to_pid('<#{pid_str}>')
      rescue
        ArgumentError ->
          raise ArgumentError, message: "Incorrect temp filepath pid: #{path}"
      end

    %{
      dir: dirname,
      pid: pid,
      id: id
    }
  end

  def filename_prefix do
    "tmp_file_cache"
  end
end
