defmodule FileCache do
  @type id :: term
  @type cache_name :: atom

  use Supervisor

  alias FileCache.AsyncPool
  alias FileCache.Temp
  alias FileCache.Perm
  alias FileCache.TempCleaner
  alias FileCache.StaleCleaner
  alias FileCache.Utils
  alias FileCache.Config

  defp options_schema() do
    namespace_single_type = {:or, [{:in, [nil, :host]}, {:fun, 0}, :mfa]}
    namespace_type = {:or, [namespace_single_type, {:list, namespace_single_type}]}

    [
      name: [
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
      ]
    ]
  end

  def init(opts) do
    config =
      opts
      |> NimbleOptions.validate!(options_schema())
      |> Map.new()

    cache_name = config[:cache_name]

    Config.store(cache_name, config)

    children = [
      [
        {AsyncPool, cache_name},
        TempCleaner,
        StaleCleaner
      ]
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp op_options_schema do
    [
      cache: [
        type: :atom,
        required: true
      ],
      id: [
        type: :string,
        required: true
      ],
      ttl: [
        type: :pos_integer
      ],
      owner: [
        type: :pid
      ],
      return: [
        type: {:choice, [:filename, :data]},
        default: :data
      ]
    ]
  end

  defp validate_op_options(opts) do
    NimbleOptions.validate!(opts, op_options_schema())
  end

  # Try to read from cache, using data from the provided fallback otherwise
  # FileCache.execute(opts, "binary/iolist/stream or fn/0, that returns any of them") # {:ok | :commit | :ignore, filepath} | {:error, _}
  def execute(enum, id, opts \\ []) do
    opts = validate_op_options(opts)

    case do_get(id, opts) do
      {:ok, cached_stream} ->
        cached_stream

      {:error, :not_found} ->
        do_put(enum, id, opts)
    end
  end

  # Overwriting execute/2
  # FileCache.put(opts, value) # {:ok, filepath} | {:error, } | no_return
  def put(enum, id, opts) do
    do_put(enum, id, validate_op_options(opts))
  end

  # Returns absolute filepath to cached item (e.g. to use in Plug.Conn.send_file)
  # This is what must be used by default for sending files as-is over network
  ### FileCache.get(id) # filepath | nil | no_return
  # Returns lazy stream by default (or binary if binary: true is provided)
  ### FileCache.get(id) # (stream | binary) | nil
  def get(id, opts \\ []) do
    opts = validate_op_options(opts)
    cache_name = opts[:cache]

    Perm.find_for_id(id, cache_name)
  end

  # Some obvious operations too
  # FileCache.exists?(id) # boolean | no_return
  def exists?(id, opts) do
    id
    |> do_get(validate_op_options(opts))
    |> Map.fetch!(:path)
    |> File.exists?()
  end

  # FileCache.del(id) # :ok | no_return
  def del(id, opts) do
    id
    |> do_get(validate_op_options(opts))
    |> Map.fetch!(:path)
    |> Utils.rm_ignore_missing()
  end

  defp do_put(enum, id, opts) do
    cache_name = opts[:cache]

    StaleCleaner.schedule_clean(id, cache_name)

    temp_filepath = Temp.file_path(id, opts[:cache], opts)

    result =
      enum
      |> data_stream!()
      |> write_to_temp(temp_filepath)

    perm_filepath = Perm.file_path(id, opts[:cache], opts)
    move_from_temp(temp_filepath, perm_filepath)

    File.stream!(perm_filepath, [:binary], :byte)

    # 0. Check if it is present in cache, return if it is, otherwise...
    # 1. get stream/list/fun
    # 2. write data to temp file if list, stream-write to temp file otherwise
    # 3. As soon as data is finished, move temp file to perm location
    # 4. Remove stale files based on timestamp
  end

  defp do_get(id, opts) do
    cache_name = opts[:cache]
    # 1. Get a list of all files like pattern
    # 2. Sort by order (higher timestamp goes first)
    # 3. Try evaluating one by one
    # 4. As soon as one is found, remove the rest

    # NOTE that we do this to
    # StaleCleaner.schedule_file_removal(files)
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

  defp write_to_temp(enum, filepath) do
    # TODO: any rescue wrappers?
    case enum do
      iodata when is_list(iodata) or is_binary(iodata) ->
        File.write!(filepath, iodata, [:binary])

      stream ->
        Enum.into(stream, File.stream!(filepath, [:binary], :byte))
    end
  end

  defp move_from_temp(temp_path, perm_path) do
    # try do
    #   File.rename!()
    # end
  end

  def remove_stale_files(id) do
    # 1. list all files containing id sorted by timestamp
    # 2. Remove the stale ones (async)
  end

  defp validate_id!(id) do
    with :ok <- Utils.validate_filepath(id) do
      id
    else
      {:error, reason} ->
        raise ArgumentError,
          message: "FileCache ID #{reason}. Got: #{inspect(id)}"
    end
  end
end
