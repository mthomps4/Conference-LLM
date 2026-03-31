defmodule JarvisWeb.Workspace.ThreadHeader do
  @moduledoc """
  Header bar for the active thread/channel.
  """
  use Phoenix.Component
  import JarvisWeb.CoreComponents

  attr :thread, :map, required: true
  attr :project, :map, default: nil
  attr :status, :string, default: "idle"
  attr :streaming_persona_name, :string, default: nil
  attr :show_settings, :boolean, default: false

  def thread_header(assigns) do
    ~H"""
    <div class="px-4 py-2 border-b border-base-300 flex items-center justify-between shrink-0 min-h-[3rem]">
      <div class="flex items-center gap-3 min-w-0">
        <%!-- Participant avatars --%>
        <div class="flex -space-x-1.5">
          <div
            :for={tp <- Enum.take(@thread.thread_personas || [], 5)}
            class="w-6 h-6 rounded-full flex items-center justify-center text-white text-[10px] font-bold border border-base-100"
            style={"background-color: #{tp.persona.color}"}
          >
            {initials(tp.persona.name)}
          </div>
        </div>

        <div class="min-w-0">
          <h2 class="font-semibold text-sm leading-tight truncate">
            {display_name(@thread)}
          </h2>
          <span class="text-xs opacity-50">
            {status_text(@status, @streaming_persona_name)}
            {if length(@thread.thread_personas || []) > 1,
              do: " · #{length(@thread.thread_personas)} agents"}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-1">
        <%!-- Spawn thread button (general channels only) --%>
        <button
          :if={@thread.type == "general"}
          phx-click="show_spawn_thread"
          class="btn btn-ghost btn-xs gap-1"
          title="Spawn a thread"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-3.5" />
          <span class="hidden sm:inline">New Thread</span>
        </button>

        <%!-- Settings --%>
        <button
          phx-click="toggle_settings"
          class={["btn btn-ghost btn-xs btn-circle", @show_settings && "btn-active"]}
        >
          <.icon name="hero-cog-6-tooth" class="size-4" />
        </button>

        <%!-- Delete (non-general only) --%>
        <button
          :if={@thread.type != "general"}
          phx-click="delete_thread"
          phx-value-id={@thread.id}
          data-confirm="Delete this thread? This cannot be undone."
          class="btn btn-ghost btn-xs btn-circle text-error/60 hover:text-error"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp display_name(%{type: "general"}), do: "# general"
  defp display_name(%{title: t}) when is_binary(t) and t != "", do: t

  defp display_name(%{thread_personas: tps}) when is_list(tps) do
    tps |> Enum.map(& &1.persona.name) |> Enum.join(", ")
  end

  defp display_name(_), do: "Thread"

  defp status_text("active", nil), do: "Working..."
  defp status_text("active", name), do: "#{name} is thinking..."
  defp status_text("waiting", _), do: "Waiting for you"
  defp status_text("error", _), do: "Error"
  defp status_text(_, _), do: "Ready"

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
