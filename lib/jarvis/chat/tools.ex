defmodule Jarvis.Chat.Tools do
  @moduledoc """
  Tool registry and dispatch. Each tool is a separate module implementing
  the `Jarvis.Chat.Tool` behaviour. To add a new tool, create the module
  and add it to the `@tools` list below.
  """

  alias Jarvis.Chat.Tools.PathSandbox

  @tools [
    Jarvis.Chat.Tools.ReadFile,
    Jarvis.Chat.Tools.WriteFile,
    Jarvis.Chat.Tools.ListDirectory,
    Jarvis.Chat.Tools.RunCommand
  ]

  @tool_map Map.new(@tools, fn mod -> {mod.name(), mod} end)

  @doc """
  Returns tool definitions in Ollama's format.
  `paths` is a list of allowed directory paths.
  `allowed_tools` optionally restricts which tools are returned.
  Returns `[]` if paths is empty (tools disabled).
  """
  def definitions(paths, allowed_tools \\ [])
  def definitions([], _allowed_tools), do: []
  def definitions(nil, _allowed_tools), do: []

  def definitions(paths, allowed_tools) when is_list(paths) do
    paths_desc = paths |> Enum.map(&PathSandbox.shorten/1) |> Enum.join(", ")

    @tools
    |> Enum.map(fn mod -> mod.definition(paths_desc) end)
    |> maybe_filter(allowed_tools)
  end

  @doc """
  Execute a tool by name with the given arguments and allowed paths.
  """
  def execute(name, args, paths) when is_list(paths) and paths != [] do
    case Map.get(@tool_map, name) do
      nil -> {:error, "Unknown tool: #{name}"}
      mod -> mod.execute(args, paths)
    end
  end

  def execute(_name, _args, _paths), do: {:error, "No file access configured for this persona"}

  @doc """
  Returns the list of all registered tool names.
  """
  def available_tools do
    Enum.map(@tools, & &1.name())
  end

  defp maybe_filter(tools, []), do: tools

  defp maybe_filter(tools, allowed) do
    Enum.filter(tools, fn %{function: %{name: name}} -> name in allowed end)
  end
end
