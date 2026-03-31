defmodule Jarvis.Chat.Tools.PathSandbox do
  @moduledoc """
  Shared path resolution and sandboxing for file-based tools.
  """

  def resolve_path(path, paths) do
    expanded = Path.expand(path)

    if Path.type(path) == :absolute || Path.type(expanded) == :absolute do
      if allowed?(expanded, paths) do
        {:ok, expanded}
      else
        {:error, "Access denied: #{shorten(path)} is not within allowed paths"}
      end
    else
      paths
      |> Enum.find_value(fn base ->
        base = Path.expand(base)
        full = Path.expand(Path.join(base, path))
        if String.starts_with?(full, base), do: {:ok, full}
      end)
      |> case do
        {:ok, _} = result -> result
        nil -> {:error, "Access denied: #{path} is not within allowed paths"}
      end
    end
  end

  def allowed?(expanded, paths) do
    Enum.any?(paths, fn base ->
      base = Path.expand(base)
      String.starts_with?(expanded, base)
    end)
  end

  def shorten(path) do
    home = Path.expand("~")
    path = to_string(path)
    if String.starts_with?(path, home), do: "~" <> String.trim_leading(path, home), else: path
  end
end
