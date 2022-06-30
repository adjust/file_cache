defmodule FileCacheTest.Helpers do
  def start_cache(opts \\ []) do
    name = name(opts)
    {dir, temp_dir} = dirs(name)

    _ =
      FileCache.start_link(
        cache: name,
        dir: dir,
        temp_dir: temp_dir
      )

    name
  end

  def clean_cache(cache) do
    File.rm_rf!(basedir(name(name: "#{cache}")))
  end

  defp name(opts) do
    opts
    |> Keyword.get_lazy(:name, fn -> random_name() end)
    |> String.to_atom()
  end

  defp basedir(name), do: "/tmp/file_cache_test_#{name}"

  defp dirs(name) do
    basedir = basedir(name)
    dir = Path.join(basedir, "perm")
    temp_dir = Path.join(basedir, "temp")

    File.mkdir_p!(dir)
    File.mkdir_p!(temp_dir)

    {dir, temp_dir}
  end

  defp random_name do
    :rand.uniform()
    |> to_string()
    |> String.slice(2..-1)
    |> Base.encode64()
  end

  def binary(data \\ 1..10) do
    IO.iodata_to_binary(iolist(data))
  end

  def iolist(data \\ 1..10) do
    Enum.to_list(stream(data))
  end

  def stream(data \\ 1..10) do
    Stream.map(data, fn e -> "#{e}\n" end)
  end

  def read!(%File.Stream{} = stream) do
    Enum.to_list(stream)
  end

  def opts(opts) do
    opts
    |> Enum.to_list()
    |> Keyword.take([:cache, :ttl])
  end
end

ExUnit.start()
