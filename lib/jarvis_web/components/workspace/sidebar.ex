defmodule JarvisWeb.Workspace.Sidebar do
  @moduledoc """
  Slack-style sidebar: projects with collapsible thread lists,
  filter tabs, and status indicators.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: JarvisWeb.Endpoint,
    router: JarvisWeb.Router,
    statics: JarvisWeb.static_paths()

  import JarvisWeb.CoreComponents

  attr :projects, :list, required: true
  attr :inbox_threads, :list, required: true
  attr :thread_statuses, :map, required: true
  attr :active_thread_id, :integer, default: nil
  attr :filter, :atom, default: :all
  attr :collapsed_projects, :any, required: true
  attr :waiting_count, :integer, default: 0
  attr :search, :string, default: ""

  def sidebar(assigns) do
    ~H"""
    <aside class="w-60 border-r border-base-300 flex flex-col bg-base-200/30 shrink-0 text-sm">
      <%!-- Header --%>
      <div class="p-3 border-b border-base-300 flex items-center justify-between">
        <span class="font-bold tracking-tight">JARVIS</span>
        <div class="flex items-center gap-1">
          <.link navigate={~p"/agents"} class="btn btn-ghost btn-xs btn-circle" title="Agents">
            <.icon name="hero-cpu-chip" class="size-4" />
          </.link>
          <button
            phx-click="show_project_form"
            class="btn btn-ghost btn-xs btn-circle"
            title="New Project"
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- Filter tabs --%>
      <div class="flex border-b border-base-300 text-xs">
        <button
          phx-click="set_filter"
          phx-value-filter="all"
          class={[
            "flex-1 py-1.5 text-center transition-colors",
            @filter == :all && "font-semibold border-b-2 border-primary text-primary"
          ]}
        >
          All
        </button>
        <button
          phx-click="set_filter"
          phx-value-filter="waiting"
          class={[
            "flex-1 py-1.5 text-center transition-colors",
            @filter == :waiting && "font-semibold border-b-2 border-warning text-warning"
          ]}
        >
          Waiting
          <span :if={@waiting_count > 0} class="ml-1 badge badge-warning badge-xs">
            {@waiting_count}
          </span>
        </button>
        <button
          phx-click="set_filter"
          phx-value-filter="active"
          class={[
            "flex-1 py-1.5 text-center transition-colors",
            @filter == :active && "font-semibold border-b-2 border-success text-success"
          ]}
        >
          Active
        </button>
      </div>

      <%!-- Search --%>
      <div class="px-2 py-1.5 border-b border-base-300">
        <input
          type="text"
          name="search"
          value={@search}
          placeholder="Search threads..."
          phx-change="search_threads"
          phx-debounce="200"
          class="input input-bordered input-xs w-full"
          autocomplete="off"
        />
      </div>

      <%!-- Scrollable project tree --%>
      <div class="flex-1 overflow-y-auto">
        <div
          :for={project <- filtered_projects(@projects, @search)}
          class="border-b border-base-300/50"
        >
          <%!-- Project header --%>
          <button
            phx-click="toggle_project"
            phx-value-id={project.id}
            class="flex items-center gap-2 w-full px-3 py-2 hover:bg-base-200 transition-colors"
          >
            <.icon
              name={
                if MapSet.member?(@collapsed_projects, project.id),
                  do: "hero-chevron-right",
                  else: "hero-chevron-down"
              }
              class="size-3 opacity-50 shrink-0"
            />
            <span class="font-semibold truncate flex-1 text-left">{project.name}</span>
            <.status_dot status={aggregate_status(project.threads, @thread_statuses)} />
          </button>

          <%!-- Threads (when expanded) --%>
          <div :if={!MapSet.member?(@collapsed_projects, project.id)} class="pb-1">
            <%= for thread <- visible_threads(project.threads, @filter, @thread_statuses, @search) do %>
              <.thread_row
                thread={thread}
                active={thread.id == @active_thread_id}
                status={thread_status(thread, @thread_statuses)}
                project_id={project.id}
              />
            <% end %>
          </div>
        </div>

        <%!-- Inbox --%>
        <div :if={
          @inbox_threads != [] && has_visible_inbox(@inbox_threads, @filter, @thread_statuses)
        }>
          <div class="px-3 py-2 text-xs font-semibold opacity-50 uppercase tracking-wider">Inbox</div>
          <%= for thread <- visible_threads(@inbox_threads, @filter, @thread_statuses, @search) do %>
            <.thread_row
              thread={thread}
              active={thread.id == @active_thread_id}
              status={thread_status(thread, @thread_statuses)}
              project_id={nil}
            />
          <% end %>
        </div>
      </div>
    </aside>
    """
  end

  attr :thread, :map, required: true
  attr :active, :boolean, default: false
  attr :status, :string, default: "idle"
  attr :project_id, :any, default: nil

  defp thread_row(assigns) do
    ~H"""
    <div class="flex items-center mx-1 group">
      <.link
        patch={thread_path(@thread, @project_id)}
        class={[
          "flex items-center gap-2 px-3 py-1 rounded transition-colors flex-1 min-w-0",
          if(@active, do: "bg-primary/10 text-primary font-medium", else: "hover:bg-base-200"),
          @thread.type == "general" && "pl-5",
          @thread.type == "thread" && "pl-7"
        ]}
      >
        <.status_dot status={@status} />
        <span class="truncate flex-1">
          {thread_display_name(@thread)}
        </span>
      </.link>
      <button
        :if={@thread.type != "general"}
        phx-click="archive_thread"
        phx-value-id={@thread.id}
        class="btn btn-ghost btn-xs btn-circle opacity-0 group-hover:opacity-40 hover:!opacity-100 shrink-0"
        title="Archive"
      >
        <.icon name="hero-archive-box" class="size-3" />
      </button>
    </div>
    """
  end

  attr :status, :string, default: "idle"

  defp status_dot(assigns) do
    ~H"""
    <span class={[
      "size-2 rounded-full shrink-0",
      status_dot_class(@status)
    ]} />
    """
  end

  defp thread_path(thread, project_id) do
    cond do
      project_id && thread.type == "general" ->
        ~p"/project/#{project_id}"

      project_id ->
        ~p"/project/#{project_id}/thread/#{thread.id}"

      true ->
        # Inbox threads have no project — use a special inbox route
        ~p"/inbox/#{thread.id}"
    end
  end

  defp thread_display_name(%{type: "general"}), do: "# general"
  defp thread_display_name(%{title: title}) when is_binary(title) and title != "", do: title

  defp thread_display_name(%{thread_personas: tps}) when is_list(tps) do
    tps |> Enum.map(& &1.persona.name) |> Enum.join(", ")
  end

  defp thread_display_name(_), do: "New thread"

  defp status_dot_class("active"), do: "bg-success animate-pulse"
  defp status_dot_class("waiting"), do: "bg-warning"
  defp status_dot_class("error"), do: "bg-error"
  defp status_dot_class("idle"), do: "bg-base-content/20"
  defp status_dot_class(_), do: "bg-base-content/20"

  defp thread_status(thread, statuses) do
    # Prefer live status from ThreadServer, fall back to DB status
    case Map.get(statuses, thread.id) do
      :streaming -> "active"
      :error -> "error"
      :idle -> thread.status || "idle"
      _ -> thread.status || "idle"
    end
  end

  defp aggregate_status(threads, statuses) do
    thread_stats = Enum.map(threads, &thread_status(&1, statuses))

    cond do
      "error" in thread_stats -> "error"
      "waiting" in thread_stats -> "waiting"
      "active" in thread_stats -> "active"
      true -> "idle"
    end
  end

  defp visible_threads(threads, filter, statuses, search) do
    threads
    |> filter_by_status(filter, statuses)
    |> filter_by_search(search)
  end

  defp filter_by_status(threads, :all, _statuses), do: threads

  defp filter_by_status(threads, filter, statuses) do
    target = Atom.to_string(filter)
    Enum.filter(threads, fn t -> thread_status(t, statuses) == target end)
  end

  defp filter_by_search(threads, ""), do: threads

  defp filter_by_search(threads, search) do
    query = String.downcase(search)

    Enum.filter(threads, fn t ->
      name = thread_display_name(t) |> String.downcase()
      String.contains?(name, query)
    end)
  end

  defp filtered_projects(projects, ""), do: projects

  defp filtered_projects(projects, search) do
    query = String.downcase(search)

    Enum.filter(projects, fn p ->
      name_match = String.contains?(String.downcase(p.name), query)

      thread_match =
        Enum.any?(p.threads, fn t ->
          String.contains?(String.downcase(thread_display_name(t)), query)
        end)

      name_match || thread_match
    end)
  end

  defp has_visible_inbox(_threads, :all, _), do: true

  defp has_visible_inbox(threads, filter, statuses) do
    Enum.any?(threads, fn t -> thread_status(t, statuses) == Atom.to_string(filter) end)
  end
end
