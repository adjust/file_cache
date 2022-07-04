defmodule FileCacheTest.Helpers do
  def start_cache(opts \\ []) do
    opts = Map.new(opts)

    {name, opts} = Map.pop(opts, :cache)
    name = name(name)

    _ =
      %{cache: name}
      |> Map.merge(opts)
      |> Map.put_new_lazy(:dir, fn -> dir(name) end)
      |> Map.put_new_lazy(:temp_dir, fn -> temp_dir(name) end)
      |> FileCache.start_link()
      |> elem(1)
      |> Process.register(name)

    name
  end

  def restart_cache(opts \\ []) do
    opts
    |> Map.new()
    |> Map.fetch!(:cache)
    |> Process.whereis()
    |> Process.exit(:normal)

    start_cache(opts)
  end

  def clean_cache(cache) do
    File.rm_rf!(cache_root_dir(name("#{cache}")))
  end

  defp name(nil), do: String.to_atom(random_string())
  defp name(name), do: name

  defp cache_root_dir(name), do: "/tmp/file_cache_test_#{name}"

  def dir(name), do: ensure_dir(name, "perm")
  def temp_dir(name), do: ensure_dir(name, "temp")

  defp ensure_dir(name, subdir) do
    dir = Path.join(cache_root_dir(name), subdir)
    File.mkdir_p!(dir)
    dir
  end

  def random_string do
    :rand.uniform()
    |> to_string()
    |> String.slice(2..-1)
    |> Base.encode64()
  end

  def binary(data \\ 1..10) do
    IO.iodata_to_binary(iodata(data))
  end

  def iodata(data \\ 1..10) do
    Enum.to_list(stream(data))
  end

  def stream(data \\ 1..10) do
    Stream.map(data, fn e -> "#{e}\n" end)
  end

  def explosive_stream(data \\ 1..10, explode_check \\ &(&1 == 5)) do
    data
    |> Stream.each(fn i ->
      if explode_check.(i) do
        throw(:explode)
      end
    end)
    |> stream()
  end

  def self_terminating_stream(data \\ 1..10, terminate_check \\ &(&1 == 5)) do
    data
    |> Stream.each(fn i ->
      if terminate_check.(i) do
        Process.exit(self(), :kill)
      end
    end)
    |> stream()
  end

  def notifying_stream(data \\ 1..10, pid \\ self()) do
    data
    |> Stream.each(&send(pid, &1))
    |> stream()
  end

  def slow_stream(data \\ 1..10, interval \\ 1_000) do
    data
    |> Stream.each(fn _ -> :timer.sleep(interval) end)
    |> stream
  end

  def read!(nil), do: nil

  def read!(%File.Stream{} = stream) do
    stream
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  rescue
    e in File.Error ->
      case e do
        %{reason: :enoent} -> nil
        _ -> reraise e, __STACKTRACE__
      end
  end

  def read!(path) when is_binary(path) do
    File.read!(path)
  end

  def opts(opts, extras \\ []) do
    opts
    |> Enum.to_list()
    |> Keyword.take([:cache, :ttl])
    |> Keyword.merge(extras)
  end

  def chmod_r(dir, chmod) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.each(&File.chmod(&1, chmod))
  end

  def find_cache_files(opts) do
    opts
    |> Keyword.fetch!(:cache)
    |> cache_root_dir()
    |> Path.join("**")
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  def wait_for_new_timestamp do
    sleep(1)
  end

  def wait_for_cleaning(time \\ 500) do
    sleep(time)
  end

  def wait_for_slow_stream(data, interval) do
    wait(Enum.count(data) * interval)
  end

  # Error is an approximate execution time for any function during test
  def wait(milliseconds \\ 0, error \\ 50) do
    sleep(milliseconds + error)
  end

  def sleep(milliseconds) do
    :timer.sleep(milliseconds)
  end

  def namespace_fun(arg), do: arg

  defmacro async(arg) do
    code =
      case arg do
        [do: block] -> block
        code -> code
      end

    quote do
      {:ok, pid} =
        Task.start_link(fn ->
          unquote(code)
        end)

      pid
    end
  end

  def assert_logs(entries, fun, opts \\ []) do
    require ExUnit.Assertions

    actual_entries =
      [colors: [enabled: false]]
      |> ExUnit.CaptureLog.capture_log(fun)
      |> String.split("\n", trim: true)
      |> Enum.map(fn entry ->
        [_timestamp, level, message] = String.split(entry, ~r/ +/, parts: 3)
        {String.to_atom(String.slice(level, 1..-2)), message}
      end)

    case Keyword.get(opts, :order, true) do
      true ->
        ExUnit.Assertions.assert(actual_entries == entries)

      false ->
        ExUnit.Assertions.assert(
          MapSet.equal?(
            MapSet.new(entries),
            MapSet.new(actual_entries)
          )
        )
    end
  end

  def assert_kill(pid, reason \\ :kill) do
    import ExUnit.Assertions

    Process.flag(:trap_exit, true)
    Process.exit(pid, reason)

    case reason do
      :kill -> ExUnit.Assertions.assert_receive({:EXIT, ^pid, :killed})
      other -> ExUnit.Assertions.assert_receive({:EXIT, ^pid, ^other})
    end

    Process.flag(:trap_exit, false)
  end
end

# Tasks are mostly IO- and timer-bound, so we can do more of them at the same time
ExUnit.configure(max_cases: System.schedulers_online() * 4)
ExUnit.start()
