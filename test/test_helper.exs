defmodule FileCacheTest.Helpers do
  def start_cache(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    name = name(name)

    _ =
      [cache: name]
      |> Keyword.merge(opts)
      |> Keyword.put_new_lazy(:dir, fn -> dir(name) end)
      |> Keyword.put_new_lazy(:temp_dir, fn -> temp_dir(name) end)
      |> FileCache.start_link()

    name
  end

  def clean_cache(cache) do
    File.rm_rf!(cache_root_dir(name("#{cache}")))
  end

  defp name(nil), do: String.to_atom(random_string())
  defp name(name), do: name

  def cache_root_dir(name), do: "/tmp/file_cache_test_#{name}"

  def dir(name), do: ensure_dir(name, "perm")
  def temp_dir(name), do: ensure_dir(name, "temp")

  defp ensure_dir(name, subdir) do
    dir = Path.join(cache_root_dir(name), subdir)
    File.mkdir_p!(dir)
    dir
  end

  defp random_string do
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

  def read!(%File.Stream{} = stream) do
    stream
    |> Enum.to_list()
    |> IO.iodata_to_binary()
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
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  def wait_for_new_timestamp do
    sleep(1)
  end

  def wait_for_async_cleaning do
    sleep(100)
  end

  def sleep(milliseconds) do
    :timer.sleep(milliseconds)
  end
end

ExUnit.start()
