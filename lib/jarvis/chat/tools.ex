defmodule Jarvis.Chat.Tools do
  @moduledoc """
  Tool definitions and execution for LLM personas.

  Each persona has their own list of allowed paths (per-thread).
  A file operation is permitted if the resolved path falls within
  ANY of the persona's allowed paths.
  """

  require Logger

  @doc """
  Returns tool definitions in Ollama's format.
  `paths` is a list of allowed directory paths.
  Returns `[]` if paths is empty (tools disabled).
  """
  def definitions([]), do: []
  def definitions(nil), do: []

  def definitions(paths) when is_list(paths) do
    paths_desc = paths |> Enum.map(&shorten/1) |> Enum.join(", ")

    [
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
                description:
                  "Absolute path or path relative to one of your accessible directories: #{paths_desc}"
              }
            },
            required: ["path"]
          }
        }
      },
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
                description:
                  "Absolute path or path relative to an accessible directory: #{paths_desc}"
              },
              content: %{
                type: "string",
                description: "The full content to write to the file"
              }
            },
            required: ["path", "content"]
          }
        }
      },
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
                description:
                  "Absolute path or path relative to an accessible directory: #{paths_desc}"
              }
            },
            required: ["path"]
          }
        }
      },
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
                description:
                  "Absolute path or path relative to an accessible directory: #{paths_desc}"
              }
            },
            required: ["command"]
          }
        }
      }
    ]
  end

  @doc """
  Execute a tool call. `paths` is the list of allowed directories.
  """
  def execute(name, args, paths) when is_list(paths) and paths != [] do
    case name do
      "read_file" -> read_file(args, paths)
      "write_file" -> write_file(args, paths)
      "list_directory" -> list_directory(args, paths)
      "run_command" -> run_command(args, paths)
      _ -> {:error, "Unknown tool: #{name}"}
    end
  end

  def execute(_name, _args, _paths), do: {:error, "No file access configured for this persona"}

  # --- Tool implementations ---

  defp read_file(%{"path" => path}, paths) do
    with {:ok, full_path} <- resolve_path(path, paths),
         true <- File.regular?(full_path) || {:error, "File not found: #{path}"},
         {:ok, content} <- File.read(full_path) do
      {:ok, content}
    else
      {:error, reason} -> {:error, to_string(reason)}
      _ -> {:error, "Could not read file: #{path}"}
    end
  end

  defp read_file(_, _), do: {:error, "Missing required parameter: path"}

  defp write_file(%{"path" => path, "content" => content}, paths) do
    with {:ok, full_path} <- resolve_path(path, paths) do
      full_path |> Path.dirname() |> File.mkdir_p!()

      case File.write(full_path, content) do
        :ok -> {:ok, "File written successfully: #{path}"}
        {:error, reason} -> {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  defp write_file(_, _), do: {:error, "Missing required parameters: path, content"}

  defp list_directory(%{"path" => path}, paths) do
    with {:ok, full_path} <- resolve_path(path, paths),
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

  defp list_directory(_, _), do: {:error, "Missing required parameter: path"}

  defp run_command(%{"command" => command} = args, paths) do
    dir = Map.get(args, "working_directory", List.first(paths))

    with {:ok, full_dir} <- resolve_path(dir, paths),
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

  defp run_command(_, _), do: {:error, "Missing required parameter: command"}

  # --- Path sandboxing ---

  # Try to resolve path against each allowed base. If the path is absolute,
  # check if it falls within any allowed path. If relative, try joining with
  # each allowed path until one matches.
  defp resolve_path(path, paths) do
    expanded = Path.expand(path)

    # If absolute path, check directly
    if Path.type(path) == :absolute || Path.type(expanded) == :absolute do
      if allowed?(expanded, paths) do
        {:ok, expanded}
      else
        {:error, "Access denied: #{shorten(path)} is not within allowed paths"}
      end
    else
      # Try each allowed base
      paths
      |> Enum.find_value(fn base ->
        base = Path.expand(base)
        full = Path.expand(Path.join(base, path))

        if String.starts_with?(full, base) do
          {:ok, full}
        end
      end)
      |> case do
        {:ok, _} = result -> result
        nil -> {:error, "Access denied: #{path} is not within allowed paths"}
      end
    end
  end

  defp allowed?(expanded, paths) do
    Enum.any?(paths, fn base ->
      base = Path.expand(base)
      String.starts_with?(expanded, base)
    end)
  end

  defp shorten(path) do
    home = Path.expand("~")
    path = to_string(path)

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end
end
