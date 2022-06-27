defmodule FileCache.Common do
  alias FileCache.Utils

  def calculate_namespace(nil), do: ""

  def calculate_namespace(many) when is_list(many) do
    many
    |> Enum.map(&do_calculate_namespace/1)
    |> Path.join()
  end

  def calculate_namespace(other), do: do_calculate_namespace(other)

  defp do_calculate_namespace(:host) do
    {:ok, host} = :inet.gethostname()
    host
  end

  defp do_calculate_namespace({m, f, a}), do: apply(m, f, a)
  defp do_calculate_namespace(f) when is_function(f, 0), do: f.()

  def validate_namespace_part(part) when is_binary(part), do: part

  def validate_namespace_part(part) do
    raise ArgumentError,
      message: "Invalid namespace part (must be a String (binary)). Got: #{inspect(part)}"
  end

  def cache_process_name(module, cache_name, opts \\ []) do
    with {:ok, atom} <- Utils.str_to_atom("#{module}.#{cache_name}", opts) do
      atom
    else
      {:error, :not_found} ->
        raise ArgumentError,
          message: "Cache \"#{cache_name}\" is not found/started"
    end
  end

  def validate_cache_name(cache_name) do
    cache_name
    |> Atom.to_string()
    |> Utils.validate_filepath()
    |> case do
      :ok -> cache_name
      {:error, _} = err -> err
    end
  end
end
