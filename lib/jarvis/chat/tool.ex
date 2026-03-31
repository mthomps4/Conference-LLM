defmodule Jarvis.Chat.Tool do
  @moduledoc """
  Behaviour for tool implementations. Each tool is a module that implements
  this behaviour and registers itself with the tool registry.

  To add a new tool:
  1. Create a module that implements this behaviour
  2. Add it to the @tools list in Jarvis.Chat.Tools
  """

  @doc "Tool name as a string (e.g., \"read_file\")"
  @callback name() :: String.t()

  @doc """
  Returns the Ollama-format tool definition.
  `paths_desc` is a human-readable string of allowed paths.
  """
  @callback definition(paths_desc :: String.t()) :: map()

  @doc """
  Execute the tool with the given arguments and allowed paths.
  Returns {:ok, result} or {:error, reason}.
  """
  @callback execute(args :: map(), paths :: [String.t()]) ::
              {:ok, String.t()} | {:error, String.t()}
end
