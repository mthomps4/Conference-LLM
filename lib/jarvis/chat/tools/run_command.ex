defmodule Jarvis.Chat.Tools.RunCommand do
  @behaviour Jarvis.Chat.Tool
  alias Jarvis.Chat.Tools.PathSandbox

  @impl true
  def name, do: "run_command"

  @impl true
  def definition(paths_desc) do
    %{
      type: "function",
      function: %{
        name: "run_command",
        description:
          "Run a shell command. " <>
            "Use this for tasks like running tests, git operations, builds, etc. " <>
            "The command runs with a 30-second timeout.",
        parameters: %{
          type: "object",
          properties: %{
            command: %{
              type: "string",
              description: "The shell command to execute, e.g. 'mix test' or 'git status'"
            },
            working_directory: %{
              type: "string",
              description: "Absolute path or path relative to: #{paths_desc}"
            }
          },
          required: ["command"]
        }
      }
    }
  end

  @impl true
  def execute(%{"command" => command} = args, paths) do
    dir = Map.get(args, "working_directory", List.first(paths))

    with {:ok, full_dir} <- PathSandbox.resolve_path(dir, paths),
         true <- File.dir?(full_dir) || {:error, "Directory not found: #{dir}"} do
      case System.cmd("sh", ["-c", command],
             cd: full_dir,
             stderr_to_stdout: true,
             env: [{"HOME", System.get_env("HOME")}]
           ) do
        {output, 0} ->
          {:ok, String.trim(output)}

        {output, code} ->
          {:ok, "Exit code #{code}:\n#{String.trim(output)}"}
      end
    else
      {:error, reason} -> {:error, to_string(reason)}
    end
  rescue
    e -> {:error, "Command failed: #{Exception.message(e)}"}
  end

  def execute(_, _), do: {:error, "Missing required parameter: command"}
end
