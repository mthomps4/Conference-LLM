defmodule Jarvis.Chat.Tools.ReadFile do
  @behaviour Jarvis.Chat.Tool
  alias Jarvis.Chat.Tools.PathSandbox

  @impl true
  def name, do: "read_file"

  @impl true
  def definition(paths_desc) do
    %{
      type: "function",
      function: %{
        name: "read_file",
        description:
          "Read the contents of a file. Returns the file content as a string. " <>
            "Use this to examine source code, configuration files, etc.",
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
         true <- File.regular?(full_path) || {:error, "File not found: #{path}"},
         {:ok, content} <- File.read(full_path) do
      {:ok, content}
    else
      {:error, reason} -> {:error, to_string(reason)}
      _ -> {:error, "Could not read file: #{path}"}
    end
  end

  def execute(_, _), do: {:error, "Missing required parameter: path"}
end
