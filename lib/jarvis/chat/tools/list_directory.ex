defmodule Jarvis.Chat.Tools.ListDirectory do
  @behaviour Jarvis.Chat.Tool
  alias Jarvis.Chat.Tools.PathSandbox

  @impl true
  def name, do: "list_directory"

  @impl true
  def definition(paths_desc) do
    %{
      type: "function",
      function: %{
        name: "list_directory",
        description:
          "List the contents of a directory. Returns file and directory names. " <>
            "Use this to explore project structure.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Absolute path or path relative to: #{paths_desc}"
            }
          },
          required: ["path"]
        }
      }
    }
  end

  @impl true
  def execute(%{"path" => path}, paths) do
    with {:ok, full_path} <- PathSandbox.resolve_path(path, paths),
         true <- File.dir?(full_path) || {:error, "Directory not found: #{path}"},
         {:ok, entries} <- File.ls(full_path) do
      entries
      |> Enum.sort()
      |> Enum.map(fn entry ->
        if File.dir?(Path.join(full_path, entry)), do: "#{entry}/", else: entry
      end)
      |> Enum.join("\n")
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, to_string(reason)}
      _ -> {:error, "Could not list directory: #{path}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required parameter: path"}
end
