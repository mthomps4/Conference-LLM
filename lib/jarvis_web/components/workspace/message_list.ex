defmodule JarvisWeb.Workspace.MessageList do
  @moduledoc """
  Renders the message list for a thread/channel.
  """
  use Phoenix.Component
  import JarvisWeb.CoreComponents

  attr :messages, :list, required: true
  attr :thread, :map, required: true
  attr :streaming, :boolean, default: false
  attr :streaming_persona_name, :string, default: nil

  def message_list(assigns) do
    ~H"""
    <div
      id="messages"
      phx-hook="ScrollBottom"
      class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
    >
      <div
        :if={@messages == []}
        class="flex items-center justify-center h-full text-base-content/30"
      >
        <div class="text-center space-y-2">
          <.icon name="hero-chat-bubble-left-right" class="size-12 mx-auto" />
          <p>No messages yet</p>
        </div>
      </div>

      <div
        :for={msg <- @messages}
        class={["flex gap-3 group", msg.role == "user" && "flex-row-reverse"]}
      >
        <%!-- Avatar --%>
        <div
          :if={msg.role == "assistant" && msg.persona}
          class="w-7 h-7 rounded-full flex items-center justify-center text-white text-xs font-bold shrink-0 mt-0.5"
          style={"background-color: #{msg.persona.color}"}
        >
          {initials(msg.persona.name)}
        </div>

        <%!-- Message bubble --%>
        <div class={["max-w-[75%] min-w-0 relative", msg.role == "user" && "text-right"]}>
          <div :if={msg.role == "assistant" && msg.persona} class="text-xs opacity-50 mb-0.5 px-1">
            {msg.persona.name}
          </div>
          <div :if={msg.role == "user"} class="text-xs opacity-50 mb-0.5 px-1">You</div>

          <div class={[
            "rounded-lg px-3 py-2 text-sm leading-relaxed inline-block text-left",
            if(msg.role == "user", do: "bg-primary text-primary-content", else: "bg-base-300")
          ]}>
            <%= if msg.content == "" and @streaming do %>
              <span class="loading loading-dots loading-xs" />
            <% else %>
              <.markdown text={msg.content || ""} />
            <% end %>
          </div>

          <%!-- Copy button --%>
          <button
            :if={msg.content && msg.content != ""}
            phx-click={
              Phoenix.LiveView.JS.dispatch("jarvis:copy",
                detail: %{text: msg.content}
              )
            }
            class="btn btn-ghost btn-xs btn-circle opacity-0 group-hover:opacity-40 hover:!opacity-100 absolute -right-8 top-0"
            title="Copy"
          >
            <.icon name="hero-clipboard-document" class="size-3" />
          </button>
        </div>
      </div>

      <%!-- Streaming indicator --%>
      <div :if={@streaming && @streaming_persona_name} class="text-xs opacity-50 px-10">
        {@streaming_persona_name} is thinking...
      </div>
    </div>
    """
  end

  defp initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"
end
