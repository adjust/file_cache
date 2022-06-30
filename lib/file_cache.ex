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

  namespace_single_type = {:or, [{:in, [nil, :host]}, {:fun, 0}, :mfa]}
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

  @op_options_schema NimbleOptions.new!(
                       cache: [
                         type: :atom,
                         required: true
                       ],
                       ttl: [
                         type: :pos_integer
                       ]
                       # TODO: do we need it? what's the usecase?
                       # owner: [
                       #   type: :pid
                       # ]
                     )

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
      {:ok, cached_stream} ->
        cached_stream

      {:error, :not_found} ->
        do_put!(enum, id, [clean: false] ++ opts)
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

  def exists?(id, opts) do
    id
    |> validate_id!()
    |> do_get!(validate_op_options!(opts))
    |> is_nil()
    |> Kernel.not()
  end

  def delete!(id, opts) do
    opts = validate_op_options!(opts)

    id
    |> validate_id!()
    |> Perm.delete(opts[:cache], opts)
  end

  defp do_put!(enum, id, opts) do
    {clean?, opts} = Keyword.pop(opts, :clean, true)
    cache_name = opts[:cache]

    # NOTE: Since for `execute!` we're cleaning perm files during `do_get!`, we can safely skip it here
    # Otherwise (for `put!`) we need to schedule cleaning
    clean? && StaleCleaner.schedule_clean(id, cache_name)

    temp_filepath = Temp.file_path(id, cache_name, opts)
    perm_filepath = Perm.file_path(id, opts[:cache], opts)

    :ok =
      enum
      |> data_stream!()
      |> write_to_temp!(temp_filepath)

    move_from_temp!(temp_filepath, perm_filepath)

    # TODO: pass :line | integer_of_bytes option here somehow
    File.stream!(perm_filepath, [:binary])
  end

  defp do_get!(id, opts) do
    case Perm.find(id, opts[:cache], opts) do
      nil -> nil
      path -> File.stream!(path)
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
        _ = Enum.into(stream, File.stream!(filepath, [:binary]))
        :ok
    end
  end

  defp move_from_temp!(temp_path, perm_path) do
    File.rename!(temp_path, perm_path)
  rescue
    e in File.RenameError ->
      Utils.rm_ignore_missing(temp_path)
      reraise e, __STACKTRACE__
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
