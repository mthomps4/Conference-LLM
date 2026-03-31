defmodule JarvisWeb.WorkspaceLive do
  use JarvisWeb, :live_view

  alias Jarvis.{Chat, Projects, Agents}
  alias Jarvis.Chat.ThreadServer

  import JarvisWeb.Workspace.Sidebar
  import JarvisWeb.Workspace.MessageList
  import JarvisWeb.Workspace.MessageInput
  import JarvisWeb.Workspace.ThreadHeader

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Jarvis.PubSub, "threads")
    end

    projects = Projects.list_projects()
    agents = Agents.list_agents()
    inbox_threads = Chat.list_inbox_threads()

    llm = Jarvis.LLM.provider()

    models =
      case llm.list_models() do
        {:ok, m} -> m
        _ -> [llm.default_model()]
      end

    # Build thread statuses from all loaded threads
    all_threads = Enum.flat_map(projects, & &1.threads) ++ inbox_threads

    statuses =
      Map.new(all_threads, fn t ->
        live_status = ThreadServer.get_status(t.id)
        {t.id, live_status}
      end)

    waiting_count = count_waiting(all_threads, statuses)

    {:ok,
     assign(socket,
       projects: projects,
       inbox_threads: inbox_threads,
       agents: agents,
       models: models,
       active_thread: nil,
       active_project: nil,
       messages: [],
       thread_statuses: statuses,
       streaming_persona_name: nil,
       form: to_form(%{"text" => ""}),
       filter: :all,
       collapsed_projects: MapSet.new(),
       waiting_count: waiting_count,
       show_project_form: false,
       show_spawn_form: false,
       show_settings: false,
       show_mentions: false,
       mention_results: [],
       spawn_selected_ids: MapSet.new(),
       spawn_label: "",
       search: "",
       decisions: [],
       page_title: "Jarvis"
     )}
  end

  @impl true
  def handle_params(%{"project_id" => project_id, "id" => thread_id}, _uri, socket) do
    project = Projects.get_project!(project_id)
    switch_to_thread(socket, project, String.to_integer(thread_id))
  end

  def handle_params(%{"id" => thread_id}, _uri, socket) do
    # Inbox thread (no project)
    switch_to_thread(socket, nil, String.to_integer(thread_id))
  end

  def handle_params(%{"project_id" => project_id}, _uri, socket) do
    project = Projects.get_project!(project_id)
    general = Projects.general_channel(project.id)

    if general do
      switch_to_thread(socket, project, general.id)
    else
      {:noreply, assign(socket, active_project: project, active_thread: nil, messages: [])}
    end
  end

  def handle_params(_params, _uri, socket) do
    unsubscribe_thread(socket)

    {:noreply,
     assign(socket,
       active_thread: nil,
       active_project: nil,
       messages: [],
       streaming_persona_name: nil,
       show_settings: false,
       page_title: "Jarvis"
     )}
  end

  defp switch_to_thread(socket, project, thread_id) do
    unsubscribe_thread(socket)

    # Subscribe BEFORE loading to avoid missing broadcasts from active streams
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Jarvis.PubSub, "thread:#{thread_id}")
      ThreadServer.ensure_started(thread_id)
    end

    thread = Chat.get_thread!(thread_id)
    messages = Chat.list_messages(thread.id)
    decisions = if project, do: Projects.list_decisions(project.id), else: []

    {:noreply,
     assign(socket,
       active_project: project,
       active_thread: thread,
       messages: messages,
       decisions: decisions,
       streaming_persona_name: nil,
       show_settings: false,
       show_spawn_form: false,
       show_mentions: false,
       page_title: thread_title(thread)
     )}
  end

  defp unsubscribe_thread(socket) do
    if old = socket.assigns[:active_thread] do
      if connected?(socket) do
        Phoenix.PubSub.unsubscribe(Jarvis.PubSub, "thread:#{old.id}")
      end
    end
  end

  # --- Events: Message submission ---

  @impl true
  def handle_event("submit", %{"text" => text}, socket) do
    text = String.trim(text)
    thread = socket.assigns.active_thread

    if text == "" || !thread do
      {:noreply, socket}
    else
      status = Map.get(socket.assigns.thread_statuses, thread.id)

      if status == :streaming do
        {:noreply, socket}
      else
        opts = build_send_opts(text, thread, socket)

        case ThreadServer.send_message(thread.id, text, opts) do
          :ok ->
            {:noreply, assign(socket, form: to_form(%{"text" => ""}))}

          {:error, :already_streaming} ->
            {:noreply, socket}

          {:error, :no_matching_agents} ->
            {:noreply,
             put_flash(socket, :error, "No matching agents found. Use @AgentName to mention one.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
        end
      end
    end
  end

  def handle_event("stop_streaming", _, socket) do
    if thread = socket.assigns.active_thread do
      ThreadServer.stop_streaming(thread.id)
    end

    {:noreply, socket}
  end

  # --- Events: @Mention ---

  def handle_event("input_changed", %{"text" => text}, socket) do
    thread = socket.assigns.active_thread

    if thread && thread.type == "general" do
      case Regex.run(~r/@(\w*)$/, text) do
        [_, query] ->
          results =
            socket.assigns.agents
            |> Enum.filter(fn a ->
              query == "" ||
                String.contains?(String.downcase(a.name), String.downcase(query))
            end)
            |> Enum.take(8)

          {:noreply,
           assign(socket,
             show_mentions: true,
             mention_results: results,
             form: to_form(%{"text" => text})
           )}

        _ ->
          {:noreply,
           assign(socket,
             show_mentions: false,
             mention_results: [],
             form: to_form(%{"text" => text})
           )}
      end
    else
      {:noreply, assign(socket, form: to_form(%{"text" => text}))}
    end
  end

  def handle_event("select_mention", %{"name" => name}, socket) do
    # Replace the partial @query with @FullName in the input
    # Quote multi-word names so parse_mentions can match them
    current_text = socket.assigns.form["text"].value || ""

    mention =
      if String.contains?(name, " "),
        do: "@\"#{name}\"",
        else: "@#{name}"

    updated_text =
      Regex.replace(~r/@\w*$/, current_text, "#{mention} ")

    {:noreply,
     assign(socket,
       form: to_form(%{"text" => updated_text}),
       show_mentions: false,
       mention_results: []
     )}
  end

  # --- Events: Project CRUD ---

  def handle_event("show_project_form", _, socket) do
    {:noreply, assign(socket, show_project_form: true)}
  end

  def handle_event("close_project_form", _, socket) do
    {:noreply, assign(socket, show_project_form: false)}
  end

  def handle_event("create_project", %{"name" => name} = params, socket) do
    color = Map.get(params, "color", "#6366f1")
    description = Map.get(params, "description", "")
    context = Map.get(params, "context", "")
    agent_ids = Map.get(params, "agent_ids", [])

    case Projects.create_project(%{
           name: name,
           color: color,
           description: description,
           context: context
         }) do
      {:ok, project} ->
        # Add selected agents to project
        agent_ids
        |> List.wrap()
        |> Enum.each(fn id ->
          Projects.add_agent_to_project(project.id, String.to_integer(id))
        end)

        projects = Projects.list_projects()

        {:noreply,
         socket
         |> assign(projects: projects, show_project_form: false)
         |> push_patch(to: ~p"/project/#{project.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create project")}
    end
  end

  def handle_event("archive_project", %{"id" => id}, socket) do
    project = Projects.get_project!(id)
    Projects.archive_project(project)
    projects = Projects.list_projects()

    socket =
      if socket.assigns.active_project && socket.assigns.active_project.id == project.id do
        push_patch(socket, to: ~p"/")
      else
        socket
      end

    {:noreply, assign(socket, projects: projects)}
  end

  # --- Events: Sidebar ---

  def handle_event("toggle_project", %{"id" => id}, socket) do
    id = String.to_integer(id)
    collapsed = socket.assigns.collapsed_projects

    collapsed =
      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)

    {:noreply, assign(socket, collapsed_projects: collapsed)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: String.to_existing_atom(filter))}
  end

  def handle_event("search_threads", %{"search" => query}, socket) do
    {:noreply, assign(socket, search: query)}
  end

  # --- Events: Spawn thread from general ---

  def handle_event("show_spawn_thread", _, socket) do
    {:noreply,
     assign(socket, show_spawn_form: true, spawn_selected_ids: MapSet.new(), spawn_label: "")}
  end

  def handle_event("close_spawn_form", _, socket) do
    {:noreply, assign(socket, show_spawn_form: false)}
  end

  def handle_event("toggle_spawn_agent", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.spawn_selected_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, spawn_selected_ids: selected)}
  end

  def handle_event("update_spawn_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, spawn_label: label)}
  end

  def handle_event("spawn_thread", _, socket) do
    project = socket.assigns.active_project
    ids = MapSet.to_list(socket.assigns.spawn_selected_ids)

    if project && ids != [] do
      title = if socket.assigns.spawn_label != "", do: socket.assigns.spawn_label, else: nil
      attrs = if title, do: %{title: title}, else: %{}

      case Chat.create_thread_in_project(project.id, ids, attrs) do
        {:ok, thread} ->
          # Carry context from #general into the new thread
          inject_general_context(socket.assigns.active_thread, thread)
          projects = Projects.list_projects()

          {:noreply,
           socket
           |> assign(projects: projects, show_spawn_form: false)
           |> push_patch(to: ~p"/project/#{project.id}/thread/#{thread.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create thread")}
      end
    else
      {:noreply, socket}
    end
  end

  # --- Events: Thread settings ---

  def handle_event("toggle_settings", _, socket) do
    {:noreply, assign(socket, show_settings: !socket.assigns.show_settings)}
  end

  def handle_event("add_decision", %{"content" => content}, socket) do
    content = String.trim(content)

    if content != "" && socket.assigns.active_project do
      project = socket.assigns.active_project
      thread = socket.assigns.active_thread

      Projects.add_decision(project.id, %{
        content: content,
        decided_by: "Owner",
        thread_id: thread && thread.id
      })

      decisions = Projects.list_decisions(project.id)
      {:noreply, assign(socket, decisions: decisions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_decision", %{"id" => id}, socket) do
    Projects.delete_decision(id)

    if project = socket.assigns.active_project do
      decisions = Projects.list_decisions(project.id)
      {:noreply, assign(socket, decisions: decisions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_project_context", %{"context" => context}, socket) do
    if project = socket.assigns.active_project do
      {:ok, updated} = Projects.update_project(project, %{context: context})
      {:noreply, assign(socket, active_project: updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_collaboration", _, socket) do
    thread = socket.assigns.active_thread
    current = get_in(thread.metadata, ["collaboration"]) == true
    meta = Map.put(thread.metadata || %{}, "collaboration", !current)
    {:ok, updated} = Chat.update_thread(thread, %{metadata: meta})
    updated = Jarvis.Repo.preload(updated, thread_personas: :persona)
    {:noreply, assign(socket, active_thread: updated)}
  end

  def handle_event("add_persona_path", %{"tp_id" => tp_id, "path" => path}, socket) do
    path = String.trim(path)

    if path != "" && File.dir?(Path.expand(path)) do
      tp = Jarvis.Repo.get!(Jarvis.Chat.ThreadPersona, tp_id)
      new_paths = (tp.paths || []) ++ [path]
      Chat.update_thread_persona(tp, %{paths: new_paths})
      {:noreply, reload_active_thread(socket)}
    else
      {:noreply, put_flash(socket, :error, "Invalid directory path")}
    end
  end

  def handle_event("remove_persona_path", %{"tp-id" => tp_id, "index" => index}, socket) do
    tp = Jarvis.Repo.get!(Jarvis.Chat.ThreadPersona, tp_id)
    idx = String.to_integer(index)
    new_paths = List.delete_at(tp.paths || [], idx)
    Chat.update_thread_persona(tp, %{paths: new_paths})
    {:noreply, reload_active_thread(socket)}
  end

  def handle_event("update_persona_thinking", %{"id" => id}, socket) do
    persona = Agents.get_agent!(id)
    Agents.update_agent(persona, %{thinking: !persona.thinking})
    {:noreply, reload_active_thread(socket)}
  end

  def handle_event("update_persona_model", %{"persona_id" => id, "model" => model}, socket) do
    persona = Agents.get_agent!(id)
    Agents.update_agent(persona, %{model: model})
    {:noreply, reload_active_thread(socket)}
  end

  def handle_event("update_persona_group_model", %{"persona_id" => id, "model" => model}, socket) do
    persona = Agents.get_agent!(id)
    value = if model == "", do: nil, else: model
    Agents.update_agent(persona, %{group_model: value})
    {:noreply, reload_active_thread(socket)}
  end

  def handle_event("add_agent_to_thread", %{"persona_id" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_agent_to_thread", %{"persona_id" => persona_id}, socket) do
    thread = socket.assigns.active_thread

    if thread do
      Chat.add_persona_to_thread(thread.id, String.to_integer(persona_id))
      {:noreply, reload_active_thread(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_agent_from_thread", %{"persona-id" => persona_id}, socket) do
    thread = socket.assigns.active_thread

    if thread do
      Chat.remove_persona_from_thread(thread.id, String.to_integer(persona_id))
      {:noreply, reload_active_thread(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("archive_thread", %{"id" => id}, socket) do
    thread = Chat.get_thread!(id)
    Chat.archive_thread(thread)
    projects = Projects.list_projects()
    inbox = Chat.list_inbox_threads()

    socket =
      if socket.assigns.active_thread && socket.assigns.active_thread.id == thread.id do
        if socket.assigns.active_project do
          push_patch(socket, to: ~p"/project/#{socket.assigns.active_project.id}")
        else
          push_patch(socket, to: ~p"/")
        end
      else
        socket
      end

    {:noreply, assign(socket, projects: projects, inbox_threads: inbox)}
  end

  def handle_event("delete_thread", %{"id" => id}, socket) do
    thread = Chat.get_thread!(id)

    if thread.type != "general" do
      Chat.delete_thread(thread)
      projects = Projects.list_projects()

      socket =
        if socket.assigns.active_project do
          push_patch(socket, to: ~p"/project/#{socket.assigns.active_project.id}")
        else
          push_patch(socket, to: ~p"/")
        end

      {:noreply, assign(socket, projects: projects)}
    else
      {:noreply, put_flash(socket, :error, "Cannot delete the general channel")}
    end
  end

  # --- PubSub: Thread-specific events ---

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message])}
  end

  def handle_info({:message_delta, message_id, delta}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn msg ->
        if msg.id == message_id do
          %{msg | content: (msg.content || "") <> delta}
        else
          msg
        end
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:message_replace, message_id, new_content}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn msg ->
        if msg.id == message_id, do: %{msg | content: new_content}, else: msg
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:message_complete, _message_id}, socket), do: {:noreply, socket}

  def handle_info({:message_error, _message_id, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Agent error: #{inspect(reason)}")}
  end

  def handle_info({:tool_use, _message_id, _name, _args}, socket), do: {:noreply, socket}
  def handle_info({:collaboration_round, _round}, socket), do: {:noreply, socket}

  def handle_info({:streaming_persona, _id, name}, socket) do
    {:noreply, assign(socket, streaming_persona_name: name)}
  end

  def handle_info({:status_changed, :idle}, socket) do
    {:noreply, assign(socket, streaming_persona_name: nil)}
  end

  def handle_info({:status_changed, _status}, socket), do: {:noreply, socket}

  # --- PubSub: Global events ---

  def handle_info({:thread_status, thread_id, status}, socket) do
    atom_status =
      case status do
        s when is_atom(s) -> s
        "active" -> :streaming
        "error" -> :error
        _ -> :idle
      end

    statuses = Map.put(socket.assigns.thread_statuses, thread_id, atom_status)

    # Refresh project data to get fresh DB status for waiting count
    projects = Projects.list_projects()
    inbox = Chat.list_inbox_threads()
    all_threads = Enum.flat_map(projects, & &1.threads) ++ inbox
    waiting = count_waiting(all_threads, statuses)

    {:noreply,
     assign(socket,
       thread_statuses: statuses,
       waiting_count: waiting,
       projects: projects,
       inbox_threads: inbox
     )}
  end

  def handle_info({:thread_updated, thread}, socket) do
    projects = Projects.list_projects()
    inbox = Chat.list_inbox_threads()

    active_thread =
      if socket.assigns.active_thread && socket.assigns.active_thread.id == thread.id do
        Chat.get_thread!(thread.id)
      else
        socket.assigns.active_thread
      end

    {:noreply,
     assign(socket, projects: projects, inbox_threads: inbox, active_thread: active_thread)}
  end

  def handle_info({:thread_created, _thread}, socket) do
    projects = Projects.list_projects()
    inbox = Chat.list_inbox_threads()
    {:noreply, assign(socket, projects: projects, inbox_threads: inbox)}
  end

  def handle_info({:thread_deleted, _thread_id}, socket) do
    projects = Projects.list_projects()
    inbox = Chat.list_inbox_threads()
    {:noreply, assign(socket, projects: projects, inbox_threads: inbox)}
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fullscreen>
      <div class="flex h-full">
        <.sidebar
          projects={@projects}
          inbox_threads={@inbox_threads}
          thread_statuses={@thread_statuses}
          active_thread_id={@active_thread && @active_thread.id}
          filter={@filter}
          collapsed_projects={@collapsed_projects}
          waiting_count={@waiting_count}
          search={@search}
        />

        <div class="flex-1 flex flex-col min-w-0">
          <%!-- No thread selected --%>
          <div
            :if={!@active_thread}
            class="flex-1 flex items-center justify-center text-base-content/30"
          >
            <div class="text-center space-y-3">
              <.icon name="hero-rectangle-group" class="size-16 mx-auto" />
              <%= if @agents == [] do %>
                <p class="text-lg">Create some agents first</p>
                <.link navigate={~p"/agents/new"} class="btn btn-primary btn-sm">
                  <.icon name="hero-cpu-chip" class="size-4" /> New Agent
                </.link>
              <% else %>
                <p class="text-lg">
                  {if @projects == [], do: "Create your first project", else: "Select a project"}
                </p>
                <button phx-click="show_project_form" class="btn btn-primary btn-sm">
                  <.icon name="hero-plus" class="size-4" /> New Project
                </button>
              <% end %>
            </div>
          </div>

          <%!-- Active thread --%>
          <div :if={@active_thread} class="flex-1 flex flex-col min-h-0">
            <.thread_header
              thread={@active_thread}
              project={@active_project}
              status={thread_display_status(@active_thread, @thread_statuses)}
              streaming_persona_name={@streaming_persona_name}
              show_settings={@show_settings}
            />

            <div class="flex-1 flex min-h-0">
              <div class="flex-1 flex flex-col min-h-0">
                <.message_list
                  messages={@messages}
                  thread={@active_thread}
                  streaming={Map.get(@thread_statuses, @active_thread.id) == :streaming}
                  streaming_persona_name={@streaming_persona_name}
                />
                <.message_input
                  form={@form}
                  thread={@active_thread}
                  streaming={Map.get(@thread_statuses, @active_thread.id) == :streaming}
                  agents={@agents}
                  show_mentions={@show_mentions}
                  mention_results={@mention_results}
                />
              </div>

              <%!-- Settings panel --%>
              <aside
                :if={@show_settings}
                class="w-72 border-l border-base-300 overflow-y-auto bg-base-200/20 p-4 shrink-0"
              >
                <div class="flex items-center justify-between mb-4">
                  <h3 class="font-semibold text-sm">Settings</h3>
                  <button phx-click="toggle_settings" class="btn btn-ghost btn-xs btn-circle">
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

                <%!-- Project context --%>
                <div :if={@active_project} class="mb-4">
                  <form
                    phx-submit="save_project_context"
                    phx-change="save_project_context"
                    phx-debounce="1000"
                  >
                    <label class="text-xs font-medium opacity-50 uppercase tracking-wider">
                      Project Context
                    </label>
                    <textarea
                      name="context"
                      class="textarea textarea-bordered w-full font-mono text-xs mt-1"
                      rows="6"
                      placeholder="Tech stack, constraints, decisions...&#10;Every agent sees this."
                    >{@active_project.context}</textarea>
                    <p class="text-xs opacity-40 mt-1">
                      Auto-saves. Injected into every agent's system prompt.
                    </p>
                  </form>
                </div>

                <%!-- Collaboration toggle (groups only) --%>
                <div :if={length(@active_thread.thread_personas) > 1} class="mb-4">
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      class="toggle toggle-sm toggle-primary"
                      checked={get_in(@active_thread.metadata, ["collaboration"]) == true}
                      phx-click="toggle_collaboration"
                    />
                    <span class="text-sm">Collaboration mode</span>
                  </label>
                  <p class="text-xs opacity-50 mt-1">Agents discuss until reaching consensus</p>
                </div>

                <%!-- Add agent to thread --%>
                <div :if={available_agents(@agents, @active_thread) != []} class="mb-4">
                  <form phx-submit="add_agent_to_thread" class="flex items-center gap-2">
                    <select name="persona_id" class="select select-bordered select-xs flex-1">
                      <option value="">Add agent...</option>
                      <option :for={a <- available_agents(@agents, @active_thread)} value={a.id}>
                        {a.name}
                      </option>
                    </select>
                    <button type="submit" class="btn btn-ghost btn-xs btn-circle">
                      <.icon name="hero-plus" class="size-4" />
                    </button>
                  </form>
                </div>

                <%!-- Participants --%>
                <h4 class="font-medium text-xs uppercase tracking-wider opacity-50 mb-2">Agents</h4>
                <div class="space-y-3">
                  <div
                    :for={tp <- @active_thread.thread_personas}
                    class="bg-base-300/50 rounded-lg p-3"
                  >
                    <div class="flex items-center gap-2 mb-2">
                      <div
                        class="w-6 h-6 rounded-full flex items-center justify-center text-white text-[10px] font-bold"
                        style={"background-color: #{tp.persona.color}"}
                      >
                        {initials(tp.persona.name)}
                      </div>
                      <span class="text-sm font-medium">{tp.persona.name}</span>
                      <span class="text-xs opacity-40 ml-auto">{tp.persona.model}</span>
                      <button
                        :if={length(@active_thread.thread_personas) > 1}
                        phx-click="remove_agent_from_thread"
                        phx-value-persona-id={tp.persona_id}
                        data-confirm={"Remove #{tp.persona.name} from this thread?"}
                        class="btn btn-ghost btn-xs btn-circle opacity-30 hover:opacity-100 hover:text-error"
                        title="Remove from thread"
                      >
                        <.icon name="hero-x-mark" class="size-3" />
                      </button>
                    </div>

                    <%!-- Paths --%>
                    <div class="text-xs space-y-1">
                      <div
                        :for={{path, idx} <- Enum.with_index(tp.paths || [])}
                        class="flex items-center gap-1"
                      >
                        <.icon name="hero-folder" class="size-3 opacity-40 shrink-0" />
                        <span class="truncate flex-1 opacity-60">{shorten_path(path)}</span>
                        <button
                          phx-click="remove_persona_path"
                          phx-value-tp-id={tp.id}
                          phx-value-index={idx}
                          class="btn btn-ghost btn-xs btn-circle opacity-40 hover:opacity-100"
                        >
                          <.icon name="hero-x-mark" class="size-3" />
                        </button>
                      </div>

                      <form phx-submit="add_persona_path" class="flex gap-1">
                        <input type="hidden" name="tp_id" value={tp.id} />
                        <input
                          type="text"
                          name="path"
                          placeholder="Add path..."
                          class="input input-bordered input-xs flex-1"
                          autocomplete="off"
                        />
                        <button type="submit" class="btn btn-ghost btn-xs btn-circle">
                          <.icon name="hero-plus" class="size-3" />
                        </button>
                      </form>
                    </div>

                    <%!-- Model --%>
                    <div class="mt-2 space-y-1">
                      <form phx-change="update_persona_model" class="flex items-center gap-2">
                        <input type="hidden" name="persona_id" value={tp.persona.id} />
                        <select name="model" class="select select-bordered select-xs flex-1">
                          <option
                            :for={m <- @models}
                            value={m}
                            selected={m == tp.persona.model}
                          >
                            {m}
                          </option>
                        </select>
                        <label
                          class="flex items-center gap-1 cursor-pointer text-xs"
                          title="Extended thinking"
                        >
                          <input
                            type="checkbox"
                            class="checkbox checkbox-xs"
                            checked={tp.persona.thinking}
                            phx-click="update_persona_thinking"
                            phx-value-id={tp.persona.id}
                          /> Think
                        </label>
                      </form>
                      <%!-- Group model --%>
                      <form
                        :if={length(@active_thread.thread_personas) > 1}
                        phx-change="update_persona_group_model"
                        class="flex items-center gap-1"
                      >
                        <input type="hidden" name="persona_id" value={tp.persona.id} />
                        <span class="text-xs opacity-40 shrink-0">Group:</span>
                        <select name="model" class="select select-bordered select-xs flex-1">
                          <option value="" selected={is_nil(tp.persona.group_model)}>
                            Same as above
                          </option>
                          <option
                            :for={m <- @models}
                            value={m}
                            selected={m == tp.persona.group_model}
                          >
                            {m}
                          </option>
                        </select>
                      </form>
                    </div>
                  </div>
                </div>

                <%!-- Decision log --%>
                <div :if={@active_project} class="mt-4 pt-4 border-t border-base-300">
                  <h4 class="font-medium text-xs uppercase tracking-wider opacity-50 mb-2">
                    Decision Log
                  </h4>
                  <div class="space-y-1 mb-2">
                    <div
                      :for={d <- @decisions}
                      class="flex items-start gap-1 text-xs group/dec"
                    >
                      <span class="opacity-40 shrink-0">
                        {Calendar.strftime(d.inserted_at, "%m/%d")}
                      </span>
                      <span class="flex-1">{d.content}</span>
                      <button
                        phx-click="delete_decision"
                        phx-value-id={d.id}
                        class="btn btn-ghost btn-xs btn-circle opacity-0 group-hover/dec:opacity-40 hover:!opacity-100 shrink-0"
                      >
                        <.icon name="hero-x-mark" class="size-3" />
                      </button>
                    </div>
                    <p :if={@decisions == []} class="text-xs opacity-30">
                      No decisions logged yet
                    </p>
                  </div>
                  <form phx-submit="add_decision" class="flex gap-1">
                    <input
                      type="text"
                      name="content"
                      placeholder="Log a decision..."
                      class="input input-bordered input-xs flex-1"
                      autocomplete="off"
                    />
                    <button type="submit" class="btn btn-ghost btn-xs btn-circle">
                      <.icon name="hero-plus" class="size-3" />
                    </button>
                  </form>
                </div>
              </aside>
            </div>
          </div>
        </div>
      </div>

      <%!-- Project creation modal --%>
      <div :if={@show_project_form} class="modal modal-open">
        <div class="modal-box">
          <h3 class="font-bold text-lg mb-4">New Project</h3>
          <form phx-submit="create_project" class="space-y-3">
            <div>
              <label class="label label-text text-sm">Name</label>
              <input
                type="text"
                name="name"
                class="input input-bordered w-full"
                required
                autocomplete="off"
              />
            </div>
            <div>
              <label class="label label-text text-sm">Description</label>
              <textarea name="description" class="textarea textarea-bordered w-full" rows="2"></textarea>
            </div>
            <div>
              <label class="label label-text text-sm">Project Context</label>
              <textarea
                name="context"
                class="textarea textarea-bordered w-full font-mono text-xs"
                rows="4"
                placeholder="Tech stack, constraints, key decisions, goals...&#10;Every agent in this project sees this in their system prompt."
              ></textarea>
              <p class="text-xs opacity-40 mt-1">
                Injected into every agent's context. Think of it as the project README.
              </p>
            </div>
            <div>
              <label class="label label-text text-sm">Color</label>
              <div class="flex gap-2">
                <label
                  :for={{_name, hex} <- Jarvis.Chat.Persona.colors()}
                  class="cursor-pointer"
                >
                  <input type="radio" name="color" value={hex} class="hidden peer" />
                  <div
                    class="w-7 h-7 rounded-full border-2 border-transparent peer-checked:border-base-content peer-checked:scale-110 transition-transform"
                    style={"background-color: #{hex}"}
                  />
                </label>
              </div>
            </div>
            <div>
              <label class="label label-text text-sm">Agents</label>
              <div class="flex flex-wrap gap-2">
                <label
                  :for={agent <- @agents}
                  class="flex items-center gap-1.5 cursor-pointer bg-base-200 rounded-lg px-2 py-1"
                >
                  <input
                    type="checkbox"
                    name="agent_ids[]"
                    value={agent.id}
                    class="checkbox checkbox-xs"
                  />
                  <div
                    class="w-4 h-4 rounded-full"
                    style={"background-color: #{agent.color}"}
                  />
                  <span class="text-sm">{agent.name}</span>
                </label>
              </div>
            </div>
            <div class="modal-action">
              <button type="button" phx-click="close_project_form" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary btn-sm">Create Project</button>
            </div>
          </form>
        </div>
        <div class="modal-backdrop" phx-click="close_project_form"></div>
      </div>

      <%!-- Spawn thread modal --%>
      <div :if={@show_spawn_form} class="modal modal-open">
        <div class="modal-box">
          <h3 class="font-bold text-lg mb-4">New Thread</h3>
          <form phx-change="update_spawn_label" class="mb-3">
            <input
              type="text"
              name="label"
              value={@spawn_label}
              placeholder="Thread name (optional)"
              class="input input-bordered w-full input-sm"
              autocomplete="off"
            />
          </form>
          <p class="text-sm opacity-60 mb-2">Select agents for this thread:</p>
          <div class="flex flex-wrap gap-2 mb-4">
            <button
              :for={agent <- @agents}
              phx-click="toggle_spawn_agent"
              phx-value-id={agent.id}
              class={[
                "flex items-center gap-1.5 rounded-lg px-2 py-1 border transition-colors",
                if(MapSet.member?(@spawn_selected_ids, agent.id),
                  do: "border-primary bg-primary/10",
                  else: "border-base-300 hover:bg-base-200"
                )
              ]}
            >
              <div
                class="w-4 h-4 rounded-full"
                style={"background-color: #{agent.color}"}
              />
              <span class="text-sm">{agent.name}</span>
            </button>
          </div>
          <div class="modal-action">
            <button phx-click="close_spawn_form" class="btn btn-ghost btn-sm">Cancel</button>
            <button
              phx-click="spawn_thread"
              disabled={MapSet.size(@spawn_selected_ids) == 0}
              class="btn btn-primary btn-sm"
            >
              Create ({MapSet.size(@spawn_selected_ids)} agents)
            </button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="close_spawn_form"></div>
      </div>
    </Layouts.app>
    """
  end

  # --- Private helpers ---

  defp build_send_opts(text, thread, _socket) do
    if thread.type == "general" do
      # Parse @mentions in general channel
      project_agents = Projects.project_agents(thread.project_id)
      {_clean, mentioned} = Chat.parse_mentions(text, project_agents)

      if mentioned != [] do
        [persona_ids: Enum.map(mentioned, & &1.id)]
      else
        # No mentions — send to all agents in the channel
        []
      end
    else
      []
    end
  end

  defp thread_display_status(thread, statuses) do
    case Map.get(statuses, thread.id) do
      :streaming -> "active"
      :error -> "error"
      :idle -> thread.status || "idle"
      _ -> thread.status || "idle"
    end
  end

  defp count_waiting(threads, statuses) do
    Enum.count(threads, fn t ->
      case Map.get(statuses, t.id) do
        :streaming -> false
        :error -> false
        _ -> t.status == "waiting"
      end
    end)
  end

  defp reload_active_thread(socket) do
    if thread = socket.assigns.active_thread do
      updated = Chat.get_thread!(thread.id)
      agents = Agents.list_agents()
      assign(socket, active_thread: updated, agents: agents)
    else
      socket
    end
  end

  defp thread_title(%{type: "general"}), do: "# general"
  defp thread_title(%{title: t}) when is_binary(t) and t != "", do: t
  defp thread_title(_), do: "Thread"

  defp initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  defp inject_general_context(nil, _new_thread), do: :ok

  defp inject_general_context(source_thread, new_thread) do
    if source_thread.type == "general" do
      # Take the last 20 messages from #general as context
      messages = Chat.list_messages(source_thread.id) |> Enum.take(-20)

      if messages != [] do
        summary =
          messages
          |> Enum.map(fn msg ->
            name = if msg.persona, do: msg.persona.name, else: "Owner"
            "[#{name}]: #{String.slice(msg.content || "", 0..500)}"
          end)
          |> Enum.join("\n\n")

        Chat.create_message(new_thread.id, %{
          role: "system",
          content:
            "Context from #general channel that led to this thread being created:\n\n#{summary}"
        })
      end
    end

    :ok
  end

  defp available_agents(all_agents, thread) do
    current_ids = Enum.map(thread.thread_personas || [], & &1.persona_id)
    Enum.reject(all_agents, fn a -> a.id in current_ids end)
  end

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end
end
