defmodule FileCache.Temp do
  @moduledoc false

  alias FileCache.Config
  alias FileCache.Common
  alias FileCache.Utils

  @sep "$"

  # File path format:
  # /temp_dir/namespace.../cache_name/tmp_file_cache_<OWNER_PID>_<UNIQUE_NUM>_<ID>

  def setup(opts), do: File.mkdir_p!(full_dir_path(opts[:cache]))

  def file_path(id, cache_name, opts \\ []) do
    owner = Access.get(opts, :owner, self())

    filename =
      "#{filename_prefix()}#{@sep}#{Utils.pid_to_string(owner)}#{@sep}#{:erlang.unique_integer()}#{@sep}#{id}"

    Path.join(full_dir_path(cache_name), filename)
  end

  def wildcard(cache_name) do
    cache_name
    |> full_dir_path()
    |> Path.join("#{filename_prefix()}#{@sep}")
    |> Utils.wildcard_suffix()
  end

  def full_dir_path(cache_name) do
    config = Config.get(cache_name)

    Path.join([
      config.temp_dir,
      Common.calculate_namespace(config.temp_namespace),
      "#{cache_name}"
    ])
  end

  def parse_filepath(path, cache_name) when is_binary(path) do
    filename = Path.basename(path)
    # dirname = Path.dirname(path)

    # NOTE: note the `parts: 4`: because ID can contain underscores, we put it specifically in the end
    # to avoid splitting it by accident
    with [prefix, pid_str, _uniq_id, id] <- String.split(filename, @sep, parts: 4),
         {:ok, _prefix} <- parse_prefix(prefix),
         {:ok, pid} <- parse_pid(pid_str) do
      {:ok,
       %{
         # dir: dirname,
         pid: pid,
         id: id
       }}
    else
      parts when is_list(parts) ->
        Common.log(:error, cache_name, "Incorrect temp filepath format: #{path}")
        {:error, :bad_format}

      {:error, :bad_prefix} = e ->
        Common.log(:error, cache_name, "Incorrect temp filepath prefix: #{path}")
        e

      {:error, :bad_pid} = e ->
        Common.log(:error, cache_name, "Incorrect temp filepath pid: #{path}")
        e
    end
  end

  defp parse_prefix(prefix) do
    case prefix == filename_prefix() do
      true -> {:ok, prefix}
      false -> {:error, :bad_prefix}
    end
  end

  defp parse_pid(pid_str) do
    {:ok, :erlang.list_to_pid(~c"<#{pid_str}>")}
  rescue
    ArgumentError ->
      {:error, :bad_pid}
  end

  def filename_prefix do
    "temp-file-cache"
  end
end
