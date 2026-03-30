defmodule JarvisWeb.ThreadLive do
  use JarvisWeb, :live_view

  alias Jarvis.Chat
  alias Jarvis.Chat.ThreadServer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Jarvis.PubSub, "threads")
    end

    threads = Chat.list_threads()
    personas = Chat.list_personas()

    models =
      case Jarvis.Ollama.list_models() do
        {:ok, m} -> m
        _ -> [Jarvis.Ollama.default_model()]
      end

    statuses = Map.new(threads, fn t -> {t.id, ThreadServer.get_status(t.id)} end)

    {:ok,
     assign(socket,
       threads: threads,
       personas: personas,
       models: models,
       active_thread: nil,
       messages: [],
       thread_statuses: statuses,
       streaming_persona_name: nil,
       form: to_form(%{"text" => ""}),
       show_new_thread: false,
       group_mode: false,
       selected_persona_ids: MapSet.new(),
       group_label: "",
       show_settings: false,
       expanded_persona_id: nil,
       page_title: "Jarvis"
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    old_thread = socket.assigns[:active_thread]
    thread = Chat.get_thread!(id)
    messages = Chat.list_messages(thread.id)

    if connected?(socket) do
      if old_thread, do: Phoenix.PubSub.unsubscribe(Jarvis.PubSub, "thread:#{old_thread.id}")
      Phoenix.PubSub.subscribe(Jarvis.PubSub, "thread:#{thread.id}")
      ThreadServer.ensure_started(thread.id)
    end

    {:noreply,
     assign(socket,
       active_thread: thread,
       messages: messages,
       streaming_persona_name: nil,
       show_new_thread: false,
       group_mode: false,
       show_settings: false,
       expanded_persona_id: nil,
       page_title: thread.title || thread_display_name(thread) || "Chat"
     )}
  end

  def handle_params(_params, _uri, socket) do
    old_thread = socket.assigns[:active_thread]

    if connected?(socket) && old_thread do
      Phoenix.PubSub.unsubscribe(Jarvis.PubSub, "thread:#{old_thread.id}")
    end

    {:noreply,
     assign(socket,
       active_thread: nil,
       messages: [],
       streaming_persona_name: nil,
       page_title: "Jarvis"
     )}
  end

  # --- Events ---

  @impl true
  def handle_event("toggle_new_thread", _params, socket) do
    {:noreply,
     assign(socket,
       show_new_thread: !socket.assigns.show_new_thread,
       group_mode: false,
       selected_persona_ids: MapSet.new(),
       group_label: ""
     )}
  end

  def handle_event("new_thread", %{"persona-id" => persona_id}, socket) do
    case Chat.create_thread(String.to_integer(persona_id)) do
      {:ok, thread} ->
        threads = [thread | socket.assigns.threads]

        {:noreply,
         socket
         |> assign(threads: threads, show_new_thread: false, group_mode: false)
         |> push_patch(to: ~p"/thread/#{thread.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create thread")}
    end
  end

  def handle_event("toggle_group_mode", _params, socket) do
    {:noreply,
     assign(socket,
       group_mode: !socket.assigns.group_mode,
       selected_persona_ids: MapSet.new(),
       group_label: ""
     )}
  end

  def handle_event("toggle_persona_selection", %{"id" => id}, socket) do
    pid = String.to_integer(id)
    selected = socket.assigns.selected_persona_ids

    selected =
      if MapSet.member?(selected, pid),
        do: MapSet.delete(selected, pid),
        else: MapSet.put(selected, pid)

    {:noreply, assign(socket, selected_persona_ids: selected)}
  end

  def handle_event("update_group_label", %{"label" => label}, socket) do
    {:noreply, assign(socket, group_label: label)}
  end

  def handle_event("create_group", _params, socket) do
    selected = socket.assigns.selected_persona_ids

    if MapSet.size(selected) < 2 do
      {:noreply, put_flash(socket, :error, "Select at least 2 contacts for a group")}
    else
      persona_ids = MapSet.to_list(selected)
      label = String.trim(socket.assigns.group_label)
      attrs = if label != "", do: %{label: label}, else: %{}

      case Chat.create_thread(persona_ids, attrs) do
        {:ok, thread} ->
          threads = [thread | socket.assigns.threads]

          {:noreply,
           socket
           |> assign(
             threads: threads,
             show_new_thread: false,
             group_mode: false,
             selected_persona_ids: MapSet.new(),
             group_label: ""
           )
           |> push_patch(to: ~p"/thread/#{thread.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create group")}
      end
    end
  end

  def handle_event("submit", %{"text" => text}, socket) when byte_size(text) > 0 do
    thread = socket.assigns.active_thread

    case ThreadServer.send_message(thread.id, text) do
      :ok ->
        {:noreply, assign(socket, form: to_form(%{"text" => ""}))}

      {:error, :already_streaming} ->
        {:noreply, put_flash(socket, :error, "Please wait for the current response")}
    end
  end

  def handle_event("submit", _params, socket), do: {:noreply, socket}

  def handle_event("stop_streaming", _params, socket) do
    if socket.assigns.active_thread do
      ThreadServer.stop_streaming(socket.assigns.active_thread.id)
    end

    {:noreply, socket}
  end

  def handle_event("toggle_settings", _params, socket) do
    {:noreply,
     assign(socket, show_settings: !socket.assigns.show_settings, expanded_persona_id: nil)}
  end

  def handle_event("expand_persona", %{"id" => id}, socket) do
    pid = String.to_integer(id)
    current = socket.assigns.expanded_persona_id

    {:noreply, assign(socket, expanded_persona_id: if(current == pid, do: nil, else: pid))}
  end

  def handle_event("save_thread_label", %{"label" => label}, socket) do
    thread = socket.assigns.active_thread
    label = String.trim(label)
    {:ok, updated} = Chat.update_thread(thread, %{label: if(label == "", do: nil, else: label)})
    updated = Jarvis.Repo.preload(updated, [thread_personas: :persona], force: true)

    threads =
      Enum.map(socket.assigns.threads, fn t ->
        if t.id == updated.id, do: updated, else: t
      end)

    {:noreply, assign(socket, active_thread: updated, threads: threads)}
  end

  def handle_event("update_persona_thinking", %{"id" => id}, socket) do
    persona = Chat.get_persona!(String.to_integer(id))
    {:ok, updated_persona} = Chat.update_persona(persona, %{thinking: !persona.thinking})

    socket = reload_active_thread(socket)

    personas =
      Enum.map(socket.assigns.personas, fn p ->
        if p.id == updated_persona.id, do: updated_persona, else: p
      end)

    {:noreply, assign(socket, personas: personas)}
  end

  def handle_event("update_persona_model", %{"persona_id" => id, "model" => model}, socket) do
    persona = Chat.get_persona!(String.to_integer(id))
    {:ok, updated_persona} = Chat.update_persona(persona, %{model: model})

    socket = reload_active_thread(socket)

    personas =
      Enum.map(socket.assigns.personas, fn p ->
        if p.id == updated_persona.id, do: updated_persona, else: p
      end)

    {:noreply, assign(socket, personas: personas)}
  end

  def handle_event("update_persona_group_model", %{"persona_id" => id, "model" => model}, socket) do
    persona = Chat.get_persona!(String.to_integer(id))
    group_model = if model == "", do: nil, else: model
    {:ok, updated_persona} = Chat.update_persona(persona, %{group_model: group_model})

    socket = reload_active_thread(socket)

    personas =
      Enum.map(socket.assigns.personas, fn p ->
        if p.id == updated_persona.id, do: updated_persona, else: p
      end)

    {:noreply, assign(socket, personas: personas)}
  end

  def handle_event("delete_thread", %{"id" => id}, socket) do
    thread = Chat.get_thread!(id)
    Jarvis.Chat.ThreadSupervisor.stop_thread(thread.id)
    {:ok, _} = Chat.delete_thread(thread)

    threads = Enum.reject(socket.assigns.threads, &(&1.id == thread.id))
    statuses = Map.delete(socket.assigns.thread_statuses, thread.id)
    socket = assign(socket, threads: threads, thread_statuses: statuses)

    socket =
      if socket.assigns.active_thread && socket.assigns.active_thread.id == thread.id do
        push_patch(socket, to: ~p"/")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("add_persona_path", %{"tp_id" => tp_id, "path" => path}, socket) do
    path = String.trim(path)
    expanded = Path.expand(path)

    cond do
      path == "" ->
        {:noreply, socket}

      !File.dir?(expanded) ->
        {:noreply, put_flash(socket, :error, "Directory not found: #{path}")}

      true ->
        tp = Jarvis.Repo.get!(Jarvis.Chat.ThreadPersona, tp_id)
        new_paths = Enum.uniq(tp.paths ++ [expanded])
        {:ok, _} = Chat.update_thread_persona(tp, %{paths: new_paths})
        {:noreply, reload_active_thread(socket)}
    end
  end

  def handle_event("remove_persona_path", %{"tp-id" => tp_id, "index" => index}, socket) do
    tp = Jarvis.Repo.get!(Jarvis.Chat.ThreadPersona, tp_id)
    idx = String.to_integer(index)
    new_paths = List.delete_at(tp.paths, idx)
    {:ok, _} = Chat.update_thread_persona(tp, %{paths: new_paths})
    {:noreply, reload_active_thread(socket)}
  end

  def handle_event("toggle_collaboration", _params, socket) do
    thread = socket.assigns.active_thread
    current = get_in(thread.metadata, ["collaboration"]) == true
    metadata = Map.put(thread.metadata || %{}, "collaboration", !current)
    {:ok, updated} = Chat.update_thread(thread, %{metadata: metadata})
    updated = Jarvis.Repo.preload(updated, [thread_personas: :persona], force: true)

    threads =
      Enum.map(socket.assigns.threads, fn t ->
        if t.id == updated.id, do: updated, else: t
      end)

    {:noreply, assign(socket, active_thread: updated, threads: threads)}
  end

  # --- PubSub: Thread-specific ---

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message])}
  end

  def handle_info({:message_delta, message_id, delta}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn msg ->
        if msg.id == message_id, do: %{msg | content: msg.content <> delta}, else: msg
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
  def handle_info({:message_error, _message_id, _reason}, socket), do: {:noreply, socket}
  def handle_info({:tool_use, _message_id, _tool_name, _args}, socket), do: {:noreply, socket}
  def handle_info({:collaboration_round, _round}, socket), do: {:noreply, socket}

  def handle_info({:streaming_persona, _persona_id, persona_name}, socket) do
    {:noreply, assign(socket, streaming_persona_name: persona_name)}
  end

  def handle_info({:status_changed, :idle}, socket) do
    {:noreply, assign(socket, streaming_persona_name: nil)}
  end

  def handle_info({:status_changed, _status}, socket), do: {:noreply, socket}

  # --- PubSub: Global ---

  def handle_info({:thread_status, thread_id, status}, socket) do
    statuses = Map.put(socket.assigns.thread_statuses, thread_id, status)
    {:noreply, assign(socket, thread_statuses: statuses)}
  end

  def handle_info({:thread_updated, thread}, socket) do
    thread = Jarvis.Repo.preload(thread, [thread_personas: :persona], force: true)

    threads =
      Enum.map(socket.assigns.threads, fn t ->
        if t.id == thread.id, do: thread, else: t
      end)

    active =
      if socket.assigns.active_thread && socket.assigns.active_thread.id == thread.id,
        do: thread,
        else: socket.assigns.active_thread

    {:noreply, assign(socket, threads: threads, active_thread: active)}
  end

  def handle_info({:thread_created, thread}, socket) do
    if Enum.any?(socket.assigns.threads, &(&1.id == thread.id)) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, threads: [thread | socket.assigns.threads])}
    end
  end

  def handle_info({:thread_deleted, thread_id}, socket) do
    threads = Enum.reject(socket.assigns.threads, &(&1.id == thread_id))
    {:noreply, assign(socket, threads: threads)}
  end

  # --- Helpers ---

  defp thread_display_name(thread) do
    case thread_personas_list(thread) do
      [] -> "Unknown"
      [p] -> p.name
      personas -> thread.label || Enum.map_join(personas, ", ", & &1.name)
    end
  end

  defp thread_personas_list(%{thread_personas: tps}) when is_list(tps) do
    Enum.map(tps, & &1.persona)
  end

  defp thread_personas_list(_), do: []

  defp first_persona(thread) do
    case thread_personas_list(thread) do
      [p | _] -> p
      [] -> nil
    end
  end

  defp is_group?(thread) do
    length(thread_personas_list(thread)) > 1
  end

  defp persona_color_for(thread) do
    case first_persona(thread) do
      nil -> "#64748b"
      p -> p.color
    end
  end

  defp message_persona_name(msg, thread) do
    cond do
      msg.role == "user" -> "You"
      msg.persona && msg.persona.name -> msg.persona.name
      true -> thread_display_name(thread)
    end
  end

  defp message_persona_color(msg, thread) do
    cond do
      msg.persona && msg.persona.color -> msg.persona.color
      true -> persona_color_for(thread)
    end
  end

  defp reload_active_thread(socket) do
    if socket.assigns.active_thread do
      thread = Chat.get_thread!(socket.assigns.active_thread.id)

      threads =
        Enum.map(socket.assigns.threads, fn t ->
          if t.id == thread.id, do: thread, else: t
        end)

      assign(socket, active_thread: thread, threads: threads)
    else
      socket
    end
  end

  defp collaboration?(%{metadata: %{"collaboration" => true}}), do: true
  defp collaboration?(_), do: false

  defp any_persona_has_paths?(%{thread_personas: tps}) when is_list(tps) do
    Enum.any?(tps, fn tp -> tp.paths != [] end)
  end

  defp any_persona_has_paths?(_), do: false

  defp shorten_path(path) do
    home = Path.expand("~")

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end

  defp initials(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp status_color(nil), do: "bg-success"
  defp status_color(:idle), do: "bg-success"
  defp status_color(:streaming), do: "bg-warning animate-pulse"
  defp status_color(:error), do: "bg-error"

  defp status_label(nil, _), do: "Ready"
  defp status_label(:idle, _), do: "Ready"
  defp status_label(:error, _), do: "Error"

  defp status_label(:streaming, streaming_persona_name) do
    if streaming_persona_name do
      "#{streaming_persona_name} is thinking..."
    else
      "Thinking..."
    end
  end

  defp streaming?(nil), do: false
  defp streaming?(:streaming), do: true
  defp streaming?(_), do: false

  defp format_time(nil), do: ""

  defp format_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "now"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86400)}d"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fullscreen>
      <div class="flex h-full">
        <%!-- Sidebar --%>
        <aside class="w-80 border-r border-base-300 flex flex-col bg-base-200/30 shrink-0">
          <div class="p-3 border-b border-base-300 flex items-center justify-between">
            <h2 class="font-semibold">Messages</h2>
            <div class="flex items-center gap-1">
              <.link
                navigate={~p"/contacts"}
                class="btn btn-ghost btn-sm btn-circle"
                title="Manage Contacts"
              >
                <.icon name="hero-user-group" class="size-5" />
              </.link>
              <button
                phx-click="toggle_new_thread"
                class="btn btn-ghost btn-sm btn-circle"
                title="New Thread"
              >
                <.icon name="hero-pencil-square" class="size-5" />
              </button>
            </div>
          </div>

          <%!-- Persona picker --%>
          <div :if={@show_new_thread} class="border-b border-base-300">
            <div class="p-3 flex items-center justify-between">
              <span class="text-sm font-medium">
                {if @group_mode, do: "New Group Chat", else: "Choose a contact"}
              </span>
              <div class="flex items-center gap-1">
                <button
                  phx-click="toggle_group_mode"
                  class={[
                    "btn btn-xs",
                    if(@group_mode, do: "btn-primary", else: "btn-ghost")
                  ]}
                  title={if @group_mode, do: "Back to direct", else: "Create group chat"}
                >
                  <.icon name="hero-user-group" class="size-3.5" /> Group
                </button>
                <button phx-click="toggle_new_thread" class="btn btn-ghost btn-xs btn-circle">
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>

            <%!-- Group mode: label input + checkboxes --%>
            <div :if={@group_mode} class="px-3 pb-2">
              <form phx-change="update_group_label" class="mb-2">
                <input
                  type="text"
                  name="label"
                  placeholder="Group label (optional)"
                  value={@group_label}
                  class="input input-bordered input-sm w-full"
                  autocomplete="off"
                />
              </form>

              <%!-- Selected pills --%>
              <div :if={MapSet.size(@selected_persona_ids) > 0} class="flex flex-wrap gap-1 mb-2">
                <span
                  :for={persona <- @personas}
                  :if={MapSet.member?(@selected_persona_ids, persona.id)}
                  class="badge badge-sm gap-1"
                  style={"background-color: #{persona.color}; color: white;"}
                >
                  {persona.name}
                  <button
                    phx-click="toggle_persona_selection"
                    phx-value-id={persona.id}
                    class="hover:opacity-70"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </span>
              </div>
            </div>

            <div :if={@personas == []} class="px-4 pb-4 text-sm opacity-50 text-center">
              <p>No contacts yet.</p>
              <.link navigate={~p"/contacts/new"} class="link link-primary">Create one</.link>
            </div>

            <div class="px-2 pb-3 space-y-1 max-h-64 overflow-y-auto">
              <button
                :for={persona <- @personas}
                phx-click={if @group_mode, do: "toggle_persona_selection", else: "new_thread"}
                phx-value-persona-id={persona.id}
                phx-value-id={persona.id}
                class={[
                  "flex items-center gap-3 p-2 rounded-lg hover:bg-base-200 transition-colors w-full text-left",
                  @group_mode && MapSet.member?(@selected_persona_ids, persona.id) &&
                    "bg-base-200 ring-2 ring-primary/30"
                ]}
              >
                <div class="relative shrink-0">
                  <div
                    class="w-9 h-9 rounded-full flex items-center justify-center text-white font-bold text-sm"
                    style={"background-color: #{persona.color}"}
                  >
                    {initials(persona.name)}
                  </div>
                  <div
                    :if={@group_mode && MapSet.member?(@selected_persona_ids, persona.id)}
                    class="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-primary flex items-center justify-center"
                  >
                    <.icon name="hero-check" class="size-3 text-primary-content" />
                  </div>
                </div>
                <div class="min-w-0">
                  <div class="text-sm font-medium truncate">{persona.name}</div>
                  <div class="text-xs opacity-60 truncate">{persona.model}</div>
                </div>
              </button>
            </div>

            <%!-- Create Group button --%>
            <div :if={@group_mode} class="px-3 pb-3">
              <button
                phx-click="create_group"
                disabled={MapSet.size(@selected_persona_ids) < 2}
                class="btn btn-primary btn-sm w-full"
              >
                Create Group ({MapSet.size(@selected_persona_ids)} selected)
              </button>
            </div>
          </div>

          <%!-- Thread list --%>
          <div class="flex-1 overflow-y-auto">
            <.link
              :for={thread <- @threads}
              patch={~p"/thread/#{thread.id}"}
              class={[
                "flex items-center gap-3 p-3 border-b border-base-300/50 hover:bg-base-200 transition-colors",
                @active_thread && @active_thread.id == thread.id && "bg-base-200"
              ]}
            >
              <%!-- Avatar: single or stacked for groups --%>
              <div
                :if={!is_group?(thread)}
                class="w-10 h-10 rounded-full flex items-center justify-center text-white font-bold text-sm shrink-0 relative"
                style={"background-color: #{persona_color_for(thread)}"}
              >
                {initials(thread_display_name(thread))}
                <span class={[
                  "absolute -bottom-0.5 -right-0.5 size-3 rounded-full border-2 border-base-100",
                  status_color(@thread_statuses[thread.id])
                ]} />
              </div>
              <div :if={is_group?(thread)} class="w-10 h-10 shrink-0 relative">
                <div
                  :for={
                    {persona, idx} <-
                      thread_personas_list(thread) |> Enum.take(3) |> Enum.with_index()
                  }
                  class="absolute w-7 h-7 rounded-full flex items-center justify-center text-white font-bold text-[10px] border-2 border-base-100"
                  style={"background-color: #{persona.color}; left: #{idx * 8}px; top: #{idx * 4}px; z-index: #{3 - idx};"}
                >
                  {initials(persona.name)}
                </div>
                <span class={[
                  "absolute -bottom-0.5 -right-0.5 size-3 rounded-full border-2 border-base-100 z-10",
                  status_color(@thread_statuses[thread.id])
                ]} />
              </div>

              <div class="min-w-0 flex-1">
                <div class="flex items-center justify-between">
                  <span class="text-sm font-medium truncate">{thread_display_name(thread)}</span>
                  <span :if={thread.last_message_at} class="text-xs opacity-50 shrink-0 ml-2">
                    {format_time(thread.last_message_at)}
                  </span>
                </div>
                <p class="text-xs opacity-60 truncate">{thread.title || "New conversation"}</p>
              </div>
            </.link>

            <div :if={@threads == []} class="p-6 text-center text-sm opacity-50">
              <p>No conversations yet.</p>
              <p class="mt-1">Create a contact and start chatting!</p>
            </div>
          </div>
        </aside>

        <%!-- Chat pane --%>
        <div class="flex-1 flex flex-col min-w-0">
          <%!-- Empty state --%>
          <div
            :if={!@active_thread}
            class="flex-1 flex items-center justify-center text-base-content/30"
          >
            <div class="text-center space-y-3">
              <.icon name="hero-chat-bubble-left-right" class="size-16 mx-auto" />
              <p class="text-lg">Select a conversation</p>
              <p class="text-sm">or create a new one to get started</p>
            </div>
          </div>

          <%!-- Active thread --%>
          <div :if={@active_thread} class="flex-1 flex flex-col min-h-0">
            <%!-- Chat header --%>
            <div class="px-4 py-3 border-b border-base-300 flex items-center justify-between shrink-0">
              <div class="flex items-center gap-3">
                <%!-- Header avatar --%>
                <div
                  :if={!is_group?(@active_thread)}
                  class="w-8 h-8 rounded-full flex items-center justify-center text-white font-bold text-xs shrink-0"
                  style={"background-color: #{persona_color_for(@active_thread)}"}
                >
                  {initials(thread_display_name(@active_thread))}
                </div>
                <div :if={is_group?(@active_thread)} class="flex -space-x-2">
                  <div
                    :for={persona <- thread_personas_list(@active_thread) |> Enum.take(4)}
                    class="w-8 h-8 rounded-full flex items-center justify-center text-white font-bold text-xs border-2 border-base-100"
                    style={"background-color: #{persona.color}"}
                  >
                    {initials(persona.name)}
                  </div>
                </div>
                <div>
                  <h2 class="font-semibold text-sm leading-tight">
                    {thread_display_name(@active_thread)}
                  </h2>
                  <span class="text-xs opacity-60">
                    {if is_group?(@active_thread),
                      do: "#{length(thread_personas_list(@active_thread))} participants",
                      else: first_persona(@active_thread) && first_persona(@active_thread).model} · {status_label(
                      @thread_statuses[@active_thread.id],
                      @streaming_persona_name
                    )}
                  </span>
                </div>
              </div>
              <div class="flex items-center gap-1">
                <%!-- Quick status badges --%>
                <span
                  :if={any_persona_has_paths?(@active_thread)}
                  class="badge badge-ghost badge-xs gap-1 opacity-60"
                >
                  <.icon name="hero-folder-open" class="size-3" /> Files
                </span>
                <span :if={collaboration?(@active_thread)} class="badge badge-primary badge-xs gap-1">
                  <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> Collab
                </span>
                <button
                  phx-click="toggle_settings"
                  class={[
                    "btn btn-ghost btn-sm btn-circle",
                    @show_settings && "btn-active"
                  ]}
                  title="Thread settings"
                >
                  <.icon name="hero-cog-6-tooth" class="size-4" />
                </button>
                <button
                  phx-click="delete_thread"
                  phx-value-id={@active_thread.id}
                  data-confirm="Delete this conversation and all messages?"
                  class="btn btn-ghost btn-sm btn-circle text-error/60 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </div>

            <div class="flex-1 flex min-h-0">
              <%!-- Messages + Input --%>
              <div class="flex-1 flex flex-col min-h-0">
                <div
                  id="messages"
                  class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
                  phx-hook="ScrollBottom"
                >
                  <div
                    :for={msg <- @messages}
                    class={["flex", if(msg.role == "user", do: "justify-end", else: "justify-start")]}
                  >
                    <div :if={msg.role != "user"} class="flex items-start gap-2 max-w-[80%]">
                      <div
                        class="w-7 h-7 rounded-full flex items-center justify-center text-white font-bold text-[10px] shrink-0 mt-5"
                        style={"background-color: #{message_persona_color(msg, @active_thread)}"}
                      >
                        {initials(message_persona_name(msg, @active_thread))}
                      </div>
                      <div class="flex flex-col">
                        <span class="text-xs opacity-50 mb-1">
                          {message_persona_name(msg, @active_thread)}
                        </span>
                        <div class="rounded-2xl px-4 py-2 bg-base-300 text-base-content rounded-bl-sm">
                          <span
                            :if={
                              msg.content == "" and streaming?(@thread_statuses[@active_thread.id])
                            }
                            class="inline-block animate-pulse"
                          >
                            ...
                          </span>
                          <.markdown :if={msg.content != ""} text={msg.content} />
                        </div>
                      </div>
                    </div>

                    <div :if={msg.role == "user"} class="flex flex-col items-end max-w-[75%]">
                      <span class="text-xs opacity-50 mb-1">You</span>
                      <div class="rounded-2xl px-4 py-2 bg-primary text-primary-content rounded-br-sm">
                        <.markdown :if={msg.content != ""} text={msg.content} />
                      </div>
                    </div>
                  </div>
                </div>

                <div class="px-4 py-3 border-t border-base-300 shrink-0">
                  <.form for={@form} phx-submit="submit" class="flex gap-2">
                    <input
                      type="text"
                      name="text"
                      value={@form[:text].value}
                      placeholder={"Message #{thread_display_name(@active_thread)}..."}
                      class="flex-1 input input-bordered"
                      autocomplete="off"
                      disabled={streaming?(@thread_statuses[@active_thread.id])}
                    />
                    <button
                      :if={!streaming?(@thread_statuses[@active_thread.id])}
                      type="submit"
                      class="btn btn-primary btn-circle"
                    >
                      <.icon name="hero-arrow-up" class="size-5" />
                    </button>
                  </.form>
                  <button
                    :if={streaming?(@thread_statuses[@active_thread.id])}
                    phx-click="stop_streaming"
                    class="btn btn-error btn-circle"
                    title="Stop generating"
                  >
                    <.icon name="hero-stop" class="size-5" />
                  </button>
                </div>
              </div>

              <%!-- Settings slide-out panel --%>
              <aside
                :if={@show_settings}
                class="w-80 border-l border-base-300 bg-base-200/30 flex flex-col shrink-0 overflow-y-auto"
              >
                <div class="p-3 border-b border-base-300 flex items-center justify-between">
                  <h3 class="font-semibold text-sm">Thread Settings</h3>
                  <button phx-click="toggle_settings" class="btn btn-ghost btn-xs btn-circle">
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

                <%!-- Thread-level settings --%>
                <div class="p-3 space-y-3 border-b border-base-300">
                  <div>
                    <label class="text-xs font-medium opacity-60">Thread Label</label>
                    <form phx-change="save_thread_label" class="mt-1">
                      <input
                        type="text"
                        name="label"
                        value={@active_thread.label || ""}
                        placeholder={thread_display_name(@active_thread)}
                        class="input input-bordered input-sm w-full"
                        autocomplete="off"
                        phx-debounce="500"
                      />
                    </form>
                  </div>

                  <div :if={is_group?(@active_thread)}>
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="checkbox"
                        class="toggle toggle-sm toggle-primary"
                        checked={collaboration?(@active_thread)}
                        phx-click="toggle_collaboration"
                      />
                      <span class="text-sm font-medium">Collaboration</span>
                    </label>
                    <p class="text-xs opacity-40 mt-1">
                      Personas discuss freely until one signals done.
                    </p>
                  </div>
                </div>

                <%!-- Participants --%>
                <div class="p-3">
                  <h4 class="text-xs font-medium opacity-60 mb-2">
                    {if is_group?(@active_thread), do: "Participants", else: "Contact"}
                  </h4>
                  <div class="space-y-1">
                    <div :for={tp <- @active_thread.thread_personas}>
                      <button
                        phx-click="expand_persona"
                        phx-value-id={tp.persona.id}
                        class={[
                          "flex items-center gap-2 p-2 rounded-lg w-full text-left transition-colors",
                          if(@expanded_persona_id == tp.persona.id,
                            do: "bg-base-300",
                            else: "hover:bg-base-200"
                          )
                        ]}
                      >
                        <div
                          class="w-8 h-8 rounded-full flex items-center justify-center text-white font-bold text-xs shrink-0"
                          style={"background-color: #{tp.persona.color}"}
                        >
                          {initials(tp.persona.name)}
                        </div>
                        <div class="min-w-0 flex-1">
                          <div class="text-sm font-medium truncate">{tp.persona.name}</div>
                          <div class="text-xs opacity-50 truncate">
                            {if is_group?(@active_thread),
                              do: tp.persona.group_model || tp.persona.model,
                              else: tp.persona.model}
                          </div>
                        </div>
                        <div class="flex items-center gap-1">
                          <span :if={tp.paths != []} class="badge badge-ghost badge-xs">
                            <.icon name="hero-folder-open" class="size-2.5" />
                          </span>
                          <.icon
                            name={
                              if @expanded_persona_id == tp.persona.id,
                                do: "hero-chevron-up",
                                else: "hero-chevron-down"
                            }
                            class="size-4 opacity-40"
                          />
                        </div>
                      </button>

                      <%!-- Expanded persona settings --%>
                      <div
                        :if={@expanded_persona_id == tp.persona.id}
                        class="ml-10 mr-2 mt-1 mb-2 space-y-3"
                      >
                        <%!-- File paths --%>
                        <div>
                          <label class="text-xs opacity-50">File Access</label>
                          <div class="mt-1 space-y-1">
                            <div
                              :for={{path, idx} <- Enum.with_index(tp.paths)}
                              class="flex items-center gap-1"
                            >
                              <span class="text-xs font-mono opacity-70 flex-1 truncate" title={path}>
                                {shorten_path(path)}
                              </span>
                              <button
                                phx-click="remove_persona_path"
                                phx-value-tp-id={tp.id}
                                phx-value-index={idx}
                                class="btn btn-ghost btn-xs btn-circle opacity-40 hover:opacity-100 hover:text-error"
                              >
                                <.icon name="hero-x-mark" class="size-3" />
                              </button>
                            </div>
                          </div>
                          <form phx-submit="add_persona_path" class="flex gap-1 mt-1">
                            <input type="hidden" name="tp_id" value={tp.id} />
                            <input
                              type="text"
                              name="path"
                              placeholder="~/Code/project/src"
                              class="input input-bordered input-xs flex-1 font-mono text-xs"
                              autocomplete="off"
                            />
                            <button type="submit" class="btn btn-ghost btn-xs btn-square">
                              <.icon name="hero-plus" class="size-3.5" />
                            </button>
                          </form>
                        </div>

                        <%!-- Model --%>
                        <div>
                          <label class="text-xs opacity-50">Model</label>
                          <form phx-change="update_persona_model" class="mt-0.5">
                            <input type="hidden" name="persona_id" value={tp.persona.id} />
                            <select name="model" class="select select-bordered select-xs w-full">
                              <option
                                :for={m <- @models}
                                value={m}
                                selected={m == tp.persona.model}
                              >
                                {m}
                              </option>
                            </select>
                          </form>
                        </div>

                        <%!-- Group Model --%>
                        <div>
                          <label class="text-xs opacity-50">Group Model</label>
                          <form phx-change="update_persona_group_model" class="mt-0.5">
                            <input type="hidden" name="persona_id" value={tp.persona.id} />
                            <select name="model" class="select select-bordered select-xs w-full">
                              <option value="" selected={is_nil(tp.persona.group_model)}>
                                Same as model
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

                        <%!-- Thinking --%>
                        <label class="flex items-center gap-2 cursor-pointer">
                          <input
                            type="checkbox"
                            class="toggle toggle-xs"
                            checked={tp.persona.thinking}
                            phx-click="update_persona_thinking"
                            phx-value-id={tp.persona.id}
                          />
                          <span class="text-xs">Thinking</span>
                        </label>

                        <%!-- System prompt preview --%>
                        <div :if={tp.persona.system_prompt}>
                          <label class="text-xs opacity-50">System Prompt</label>
                          <p class="text-xs opacity-40 mt-0.5 line-clamp-3 font-mono">
                            {tp.persona.system_prompt}
                          </p>
                        </div>

                        <.link
                          navigate={~p"/contacts/#{tp.persona.id}/edit"}
                          class="text-xs link link-primary"
                        >
                          Edit full profile
                        </.link>
                      </div>
                    </div>
                  </div>
                </div>
              </aside>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
