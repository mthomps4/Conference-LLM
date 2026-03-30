defmodule Jarvis.Ollama do
  use GenServer

  require Logger

  @base_url "http://localhost:11434"
  @default_model "qwen3:8b"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a list of messages and get a response.

      Jarvis.Ollama.chat([%{role: "user", content: "Hello"}])
  """
  def chat(messages, model \\ @default_model) when is_list(messages) do
    GenServer.call(__MODULE__, {:chat, messages, model}, :timer.seconds(120))
  end

  @doc """
  List available models from Ollama.
  """
  def list_models do
    GenServer.call(__MODULE__, :list_models)
  end

  @doc """
  Stream a chat response, sending chunks to the given process.

  Options:
    - `:tools` — list of tool definitions (Ollama format) to enable tool calling

  Sends:
    - `{:ollama_chunk, content}` for each token
    - `{:ollama_tool_calls, tool_calls}` when the model wants to call tools
    - `:ollama_done` when generation is complete (text-only, no tool calls)
    - `{:ollama_error, reason}` on failure
  """
  def stream_chat(pid, messages, model \\ @default_model, opts \\ [])
      when is_list(messages) do
    tools = Keyword.get(opts, :tools, [])
    think = Keyword.get(opts, :think, false)

    body =
      %{model: model, messages: messages, stream: true, think: think}
      |> maybe_add_tools(tools)

    Task.start(fn ->
      case Req.post("#{@base_url}/api/chat",
             json: body,
             receive_timeout: :timer.seconds(120),
             into: fn {:data, data}, {req, resp} ->
               data
               |> String.split("\n", trim: true)
               |> Enum.each(fn line ->
                 case Jason.decode(line) do
                   {:ok, %{"message" => %{"tool_calls" => tool_calls}}}
                   when is_list(tool_calls) and tool_calls != [] ->
                     send(pid, {:ollama_tool_calls, tool_calls})

                   {:ok, %{"message" => %{"content" => content}, "done" => done}} ->
                     if content != "", do: send(pid, {:ollama_chunk, content})
                     if done, do: send(pid, :ollama_done)

                   _ ->
                     :ok
                 end
               end)

               {:cont, {req, resp}}
             end
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> send(pid, {:ollama_error, reason})
      end
    end)
  end

  def default_model, do: @default_model

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:chat, messages, model}, _from, state) do
    body = %{model: model, messages: messages, stream: false}

    case Req.post("#{@base_url}/api/chat", json: body, receive_timeout: :timer.seconds(120)) do
      {:ok, %Req.Response{status: 200, body: %{"message" => %{"content" => content}}}} ->
        {:reply, {:ok, content}, state}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Ollama returned #{status}: #{inspect(body)}")
        {:reply, {:error, {status, body}}, state}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_models, _from, state) do
    case Req.get("#{@base_url}/api/tags") do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} ->
        names = Enum.map(models, & &1["name"])
        {:reply, {:ok, names}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)
end
