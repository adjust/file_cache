defmodule FileCache.Config do
  @moduledoc false

  defp pt_key(cache_name) do
    {FileCache, cache_name}
  end

  def store(cache_name, config) do
    :persistent_term.put(pt_key(cache_name), config)
  end

  def get(cache_name) when is_atom(cache_name) do
    :persistent_term.get(pt_key(cache_name))
  rescue
    ArgumentError ->
      raise ArgumentError, message: "Cache #{cache_name} is not found"
  end

  def get(cache_name, key) when is_atom(cache_name) and is_atom(key) do
    case Map.fetch(get(cache_name), key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, message: "Unknown cache config key: #{key}"
    end
  end
end
