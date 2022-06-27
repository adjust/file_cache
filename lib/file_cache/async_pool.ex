defmodule FileCache.AsyncPool do
  alias FileCache.Common

  def name(cache_name), do: name(cache_name, [])

  defp name(cache_name, opts) do
    Common.cache_process_name(__MODULE__, cache_name, opts)
  end

  def child_spec(cache_name) do
    Task.Supervisor.child_spec(name: name(cache_name, create: true))
  end
end
