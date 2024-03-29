defmodule FileCache do
  @moduledoc """
  TODO
  """
  @type id :: term
  @type cache :: atom

  use Supervisor

  alias FileCache.Temp
  alias FileCache.Perm
  alias FileCache.TempCleaner
  alias FileCache.StaleCleaner
  alias FileCache.Utils
  alias FileCache.Config

  namespace_single_type = {:or, [{:in, [nil, :host]}, :string, {:fun, 0}, :mfa]}
  namespace_type = {:or, [namespace_single_type, {:list, namespace_single_type}]}

  @init_options_schema NimbleOptions.new!(
                         cache: [
                           type: {:custom, FileCache.Common, :validate_cache_name, []},
                           required: true
                         ],
                         dir: [
                           type: :string,
                           required: true
                         ],
                         ttl: [
                           type: :pos_integer,
                           # 1 Hour
                           default: 1 * 60 * 60 * 1000
                         ],
                         namespace: [
                           type: namespace_type,
                           default: nil
                         ],
                         stale_clean_interval: [
                           type: :pos_integer,
                           # 1 Hour
                           default: 1 * 60 * 60 * 1000
                         ],
                         temp_dir: [
                           type: :string,
                           required: true
                         ],
                         # tmp directory: prefix by hostname # for NFS-like storages that might be shared
                         temp_namespace: [
                           type: namespace_type,
                           default: nil
                         ],
                         temp_clean_interval: [
                           type: :pos_integer,
                           # 15 minutes
                           default: 15 * 60 * 1000
                         ],
                         unknown_files: [
                           type: {:in, [:keep, :remove]},
                           default: :keep
                         ],
                         verbose: [
                           type: :boolean,
                           default: false
                         ]
                       )

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    config =
      opts
      |> Enum.to_list()
      |> NimbleOptions.validate!(@init_options_schema)
      |> Map.new()

    cache_name = config[:cache]

    Config.store(cache_name, config)

    Temp.setup(config)
    Perm.setup(config)

    children = [
      {TempCleaner, opts},
      {StaleCleaner, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @common_options_schema NimbleOptions.new!(
                           cache: [
                             type: :atom,
                             required: true
                           ]
                         )

  @op_options_schema NimbleOptions.new!(
                       @common_options_schema.schema ++
                         [
                           ttl: [
                             type: :pos_integer
                           ]
                         ]
                     )

  defp validate_common_options!(opts) do
    NimbleOptions.validate!(Enum.to_list(opts), @common_options_schema)
  end

  defp validate_op_options!(opts) do
    NimbleOptions.validate!(Enum.to_list(opts), @op_options_schema)
  end

  @doc """
  Try to read from cache, using data from the provided fallback otherwise
  """
  def execute!(enum, id, opts \\ []) do
    id = validate_id!(id)
    opts = validate_op_options!(opts)

    case do_get!(id, opts) do
      nil ->
        do_put!(enum, id, [clean: false] ++ opts)

      cached_stream ->
        cached_stream
    end
  end

  # Overwriting execute/2
  # FileCache.put(opts, value) # {:ok, filepath} | {:error, } | no_return
  def put!(enum, id, opts) do
    do_put!(enum, validate_id!(id), validate_op_options!(opts))
  end

  @doc """
  Returns File.Stream of cached data or nil if not found

  NOTE: if filepath of the cache is required (e.g. to use in `Plug.Conn.send_file`),
  it can be fetched with `Map.fetch!(file_stream, :path)`
  """
  def get!(id, opts \\ []) do
    do_get!(validate_id!(id), validate_op_options!(opts))
  end

  @doc """
  Works as `get!/2`, but returns all data about cache file: path, expiration, etc.

  Useful when it's required to set HTTP's Cache-Control header
  or work with cache file manually (e.g. pass its path to external program)
  """
  def get_record!(id, opts \\ []) do
    do_get_record!(validate_id!(id), validate_op_options!(opts))
  end

  def exists?(id, opts) do
    id
    |> validate_id!()
    |> do_get!(validate_op_options!(opts))
    |> is_nil()
    |> Kernel.not()
  end

  def delete!(id, opts) do
    opts = validate_common_options!(opts)

    id
    |> validate_id!()
    |> Perm.delete(opts[:cache], opts)
  end

  @doc """
  Clean cache by removing all cache files.

  NOTE: In-progress caching operations are not interrupted, i.e. temporary files will not be deleted.
  """
  def clean(opts) do
    opts = validate_common_options!(opts)

    opts[:cache]
    |> Perm.find_all(sync_clean?: true)
    |> Enum.each(fn {_id, record} -> Utils.rm_ignore_missing(record.path) end)
  end

  @doc """
  Get current statistics for the cache:
  - `current`: current number of cache files
  - `in_progress`: number of cache writes running right now
  """
  def stats(opts) do
    opts = validate_common_options!(opts)

    %{
      current: Enum.count(Perm.find_all(opts[:cache])),
      in_progress: Enum.count(Temp.wildcard(opts[:cache]))
    }
  end

  @doc """
  Get configuration of the cache reflecting its initial configuration
  """
  def config(opts) do
    FileCache.Config.get(validate_common_options!(opts)[:cache])
  end

  defp do_put!(enum, id, opts) do
    {preclean?, opts} = Keyword.pop(opts, :preclean, true)
    cache_name = opts[:cache]

    # NOTE: Since for `execute!` we're cleaning perm files during `do_get!`, we can safely skip it here
    # Otherwise (for `put!`) we need to schedule cleaning
    #
    # Why preclean? Just to save some space
    preclean? && StaleCleaner.schedule_clean(id, cache_name)

    temp_filepath = Temp.file_path(id, cache_name, opts)
    perm_filepath = Perm.file_path(id, opts[:cache], opts)

    try do
      :ok =
        enum
        |> data_stream!()
        |> write_to_temp!(temp_filepath)

      File.rename!(temp_filepath, perm_filepath)

      # NOTE: Since previous clean above we added fresher data,
      # so let's ensure that now-irrelevant cache-file is cleaned
      StaleCleaner.schedule_clean(id, cache_name)

      # TODO: pass :line | integer_of_bytes option here somehow
      File.stream!(perm_filepath)
    after
      Utils.rm_ignore_missing(temp_filepath)
    end
  end

  defp do_get!(id, opts) do
    with result when is_map(result) <- Perm.find(id, opts[:cache], opts) do
      File.stream!(result.path)
    end
  end

  def do_get_record!(id, opts) do
    with result when is_map(result) <- Perm.find(id, opts[:cache], opts) do
      %FileCache.Record{
        id: result.id,
        path: result.path,
        expires_at: result.expires_at,
        ttl: result.expires_at - Utils.system_time(),
        stream: File.stream!(result.path)
      }
    end
  end

  defp data_stream!(fun) when is_function(fun, 0) do
    do_data_stream!(fun.())
  end

  defp data_stream!(other), do: do_data_stream!(other)

  defp do_data_stream!(data) do
    cond do
      is_list(data) ->
        data

      is_binary(data) ->
        data

      Enumerable.impl_for(data) ->
        data

      true ->
        raise ArgumentError,
          message:
            "Passed data is not iodata, stream, or function that yields them. Got: #{inspect(data)}"
    end
  end

  defp write_to_temp!(enum, filepath) do
    case enum do
      iodata when is_list(iodata) or is_binary(iodata) ->
        File.write!(filepath, iodata, [:binary])

      stream ->
        _ = Enum.into(stream, File.stream!(filepath))
        :ok
    end
  end

  defp validate_id!(id) do
    with :ok <- Utils.validate_dirname(id) do
      id
    else
      {:error, reason} ->
        raise ArgumentError,
          message: "FileCache ID #{reason}. Got: #{inspect(id)}"
    end
  end
end
