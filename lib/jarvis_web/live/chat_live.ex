defmodule JarvisWeb.ChatLive do
  use JarvisWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    models =
      case Jarvis.Ollama.list_models() do
        {:ok, models} -> models
        _ -> [Jarvis.Ollama.default_model()]
      end

    {:ok,
     assign(socket,
       messages: [],
       models: models,
       selected_model: Jarvis.Ollama.default_model(),
       loading: false,
       form: to_form(%{"text" => ""})
     )}
  end

  @impl true
  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected_model: model)}
  end

  def handle_event("submit", %{"text" => text}, socket) when text != "" do
    user_msg = %{role: "user", content: text}
    history = socket.assigns.messages ++ [user_msg]

    model = socket.assigns.selected_model
    Jarvis.Ollama.stream_chat(self(), api_messages(history), model)

    {:noreply,
     assign(socket,
       messages: history ++ [%{role: "assistant", content: ""}],
       loading: true,
       form: to_form(%{"text" => ""})
     )}
  end

  def handle_event("submit", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:ollama_chunk, content}, socket) do
    messages =
      List.update_at(socket.assigns.messages, -1, fn msg ->
        %{msg | content: msg.content <> content}
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info(:ollama_done, socket) do
    {:noreply, assign(socket, loading: false)}
  end

  def handle_info({:ollama_error, reason}, socket) do
    messages =
      List.update_at(socket.assigns.messages, -1, fn msg ->
        %{msg | content: "Error: #{inspect(reason)}"}
      end)

    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  defp api_messages(messages) do
    Enum.map(messages, fn %{role: role, content: content} ->
      %{role: role, content: content}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-[calc(100vh-8rem)]">
      <div class="flex items-center gap-3 pb-3 border-b border-base-300">
        <h1 class="text-lg font-semibold">Chat</h1>
        <select
          class="rounded-lg bg-base-200 border border-base-300 px-2 py-1 text-sm"
          phx-change="select_model"
          name="model"
        >
          <option :for={model <- @models} value={model} selected={model == @selected_model}>
            {model}
          </option>
        </select>
      </div>

      <div id="messages" class="flex-1 overflow-y-auto py-2 space-y-3" phx-hook="ScrollBottom">
        <div :for={msg <- @messages} class={["flex flex-col", if(msg.role == "user", do: "items-end", else: "items-start")]}>
          <span class="text-xs opacity-50 mb-1">
            {if msg.role == "user", do: "You", else: @selected_model}
          </span>
          <div class={[
            "rounded-xl px-4 py-2 max-w-[75%]",
            if(msg.role == "user", do: "bg-primary text-primary-content", else: "bg-neutral text-neutral-content")
          ]}>
            <span :if={msg.content == "" and @loading} class="inline-block animate-pulse">...</span>
            <.markdown :if={msg.content != ""} text={msg.content} />
          </div>
        </div>
      </div>

      <div class="pt-3 border-t border-base-300">
        <.form for={@form} phx-submit="submit" class="flex gap-2">
          <input
            type="text"
            name="text"
            value={@form[:text].value}
            placeholder="Type a message..."
            class="flex-1 rounded-lg bg-base-200 border border-base-300 px-3 py-2"
            autocomplete="off"
            disabled={@loading}
          />
          <button
            type="submit"
            class="rounded-lg bg-primary text-primary-content px-4 py-2 font-medium hover:opacity-90 disabled:opacity-50"
            disabled={@loading}
          >
            Send
          </button>
        </.form>
      </div>
    </div>
    """
  end
end
