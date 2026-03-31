defmodule Jarvis.Chat.Tools.WriteFile do
  @behaviour Jarvis.Chat.Tool
  alias Jarvis.Chat.Tools.PathSandbox

  @impl true
  def name, do: "write_file"

  @impl true
  def definition(paths_desc) do
    %{
      type: "function",
      function: %{
        name: "write_file",
        description:
          "Write content to a file. Creates the file if it doesn't exist, " <>
            "or overwrites it if it does. Creates parent directories as needed.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Absolute path or path relative to: #{paths_desc}"
            },
            content: %{
              type: "string",
              description: "The full content to write to the file"
            }
          },
          required: ["path", "content"]
        }
      }
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}, paths) do
    with {:ok, full_path} <- PathSandbox.resolve_path(path, paths) do
      full_path |> Path.dirname() |> File.mkdir_p!()

      case File.write(full_path, content) do
        :ok -> {:ok, "File written successfully: #{path}"}
        {:error, reason} -> {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required parameters: path, content"}
end
