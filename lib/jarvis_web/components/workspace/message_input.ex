defmodule JarvisWeb.Workspace.MessageInput do
  @moduledoc """
  Message input with @mention autocomplete for general channels.
  """
  use Phoenix.Component
  import JarvisWeb.CoreComponents

  attr :form, :map, required: true
  attr :thread, :map, required: true
  attr :streaming, :boolean, default: false
  attr :agents, :list, default: []
  attr :mention_results, :list, default: []
  attr :show_mentions, :boolean, default: false

  def message_input(assigns) do
    ~H"""
    <div class="border-t border-base-300 px-4 py-3 shrink-0">
      <%!-- @mention dropdown --%>
      <div
        :if={@show_mentions && @mention_results != []}
        class="mb-2 bg-base-200 rounded-lg border border-base-300 shadow-lg max-h-40 overflow-y-auto"
      >
        <button
          :for={agent <- @mention_results}
          phx-click="select_mention"
          phx-value-name={agent.name}
          class="flex items-center gap-2 w-full px-3 py-1.5 hover:bg-base-300 transition-colors text-sm text-left"
          type="button"
        >
          <div
            class="w-5 h-5 rounded-full flex items-center justify-center text-white text-[10px] font-bold shrink-0"
            style={"background-color: #{agent.color}"}
          >
            {initials(agent.name)}
          </div>
          <span>{agent.name}</span>
          <span class="text-xs opacity-40 ml-auto">{agent.model}</span>
        </button>
      </div>

      <.form
        for={@form}
        phx-submit="submit"
        phx-change="input_changed"
        class="flex items-center gap-2"
      >
        <input
          type="text"
          name="text"
          value={@form["text"].value || ""}
          placeholder={input_placeholder(@thread)}
          class="input input-bordered input-sm flex-1"
          autocomplete="off"
          disabled={@streaming}
        />
        <%= if @streaming do %>
          <button type="button" phx-click="stop_streaming" class="btn btn-error btn-sm btn-circle">
            <.icon name="hero-stop" class="size-4" />
          </button>
        <% else %>
          <button type="submit" class="btn btn-primary btn-sm btn-circle">
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
        <% end %>
      </.form>

      <div :if={@thread.type == "general"} class="text-xs opacity-40 mt-1 px-1">
        Use @name to mention an agent
      </div>
    </div>
    """
  end

  defp input_placeholder(%{type: "general"}), do: "Message #general — use @agent to mention..."
  defp input_placeholder(%{title: title}) when is_binary(title), do: "Message #{title}..."
  defp input_placeholder(_), do: "Type a message..."

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
