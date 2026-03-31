defmodule Jarvis.LLM do
  @moduledoc """
  Behaviour for LLM providers. Implement this to add new backends
  (Ollama, vLLM, llama.cpp, cloud APIs).

  The message protocol uses standard process messages:
    - `{:ollama_chunk, content}` — streamed token
    - `{:ollama_tool_calls, tool_calls}` — model wants to call tools
    - `:ollama_done` — generation complete
    - `{:ollama_error, reason}` — failure

  Note: message names use the `:ollama_` prefix for backwards compatibility.
  Future providers should send the same message shapes.
  """

  @doc """
  Stream a chat response to the given process.

  Options:
    - `:tools` — list of tool definitions
    - `:think` — enable extended thinking
  """
  @callback stream_chat(pid :: pid(), messages :: list(), model :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  List available models.
  """
  @callback list_models() :: {:ok, [String.t()]} | {:error, any()}

  @doc """
  Blocking chat call (non-streaming).
  """
  @callback chat(messages :: list(), model :: String.t()) ::
              {:ok, String.t()} | {:error, any()}

  @doc """
  Returns the default model name for this provider.
  """
  @callback default_model() :: String.t()

  @doc """
  Returns the configured LLM provider module.
  """
  def provider do
    Application.get_env(:jarvis, :llm_provider, Jarvis.Ollama)
  end
end
