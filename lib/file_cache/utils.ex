defmodule FileCache.Utils do
  def escape_path_for_wildcard(path) do
    path
    |> IO.iodata_to_binary()
    |> String.replace(~r"[?[\]{}*]", &[?\\, &1], global: true)
  end

  @doc """
  Convert PID to string

    iex> pid_to_string(IEx.Helpers.pid("0.0.0"))
    "0.0.0"
  """
  def pid_to_string(pid) do
    pid
    |> inspect()
    |> String.slice(5..-2)
  end

  def rm_ignore_missing(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  def wildcard_suffix(prefix, suffix \\ "*") do
    prefix
    |> escape_path_for_wildcard()
    |> Kernel.<>(suffix)
    |> Path.wildcard()
  end

  def system_time(unit \\ :millisecond) do
    System.convert_time_unit(System.os_time(), :system, unit)
  end

  def validate_filepath(str) when is_binary(str) do
    cond do
      not is_binary(str) ->
        {:error, "must be a String (binary)"}

      String.contains?(str, "/") ->
        {:error, ~s|should not contain forward slashes ("/")|}

      true ->
        :ok
    end
  end

  def str_to_atom(str, opts) do
    case Keyword.get(opts, :create) do
      true ->
        {:ok, String.to_atom(str)}

      _ ->
        try do
          {:ok, String.to_existing_atom(str)}
        rescue
          ArgumentError ->
            {:error, :not_found}
        end
    end
  end
end
