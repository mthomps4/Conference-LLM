defmodule Jarvis.Chat.ThreadServer do
  @moduledoc """
  Per-thread GenServer managing LLM interaction state.

  States: :idle | :streaming | :error

  Supports group chats where multiple personas respond in sequence.
  Supports collaboration mode where personas discuss until reaching [DONE].
  Supports tool calling with an agent loop.

  PubSub topics:
    - "thread:{id}"  — per-thread events (new_message, message_delta, etc.)
    - "threads"      — global events (thread_status, thread_updated)
  """
  use GenServer, restart: :temporary

  require Logger

  alias Jarvis.Chat
  alias Jarvis.Chat.Tools
  alias Phoenix.PubSub

  @idle_timeout :timer.minutes(10)
  @max_tool_rounds 20
  @max_collaboration_rounds 50
  @done_signal "[DONE]"

  # --- Client API ---

  def start_link(thread_id) do
    GenServer.start_link(__MODULE__, thread_id, name: via(thread_id))
  end

  def ensure_started(thread_id) do
    case Registry.lookup(Jarvis.Chat.ThreadRegistry, thread_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> Jarvis.Chat.ThreadSupervisor.start_thread(thread_id)
    end
  end

  def send_message(thread_id, content, opts \\ []) do
    {:ok, _pid} = ensure_started(thread_id)
    GenServer.call(via(thread_id), {:send_message, content, opts})
  end

  def stop_streaming(thread_id) do
    case Registry.lookup(Jarvis.Chat.ThreadRegistry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, :stop_streaming)
      [] -> :ok
    end
  end

  def get_status(thread_id) do
    case Registry.lookup(Jarvis.Chat.ThreadRegistry, thread_id) do
      [{pid, _}] -> GenServer.call(pid, :get_status)
      [] -> :idle
    end
  end

  defp via(thread_id) do
    {:via, Registry, {Jarvis.Chat.ThreadRegistry, thread_id}}
  end

  # --- Server Callbacks ---

  @impl true
  def init(thread_id) do
    state = %{
      thread_id: thread_id,
      status: :idle,
      current_message_id: nil,
      current_persona: nil,
      pending_personas: [],
      project_context: nil,
      buffer: "",
      ollama_history: [],
      tool_round: 0,
      # Collaboration state
      all_personas: [],
      collaboration: false,
      current_round: 1,
      done_signaled: false,
      idle_timer: schedule_idle_timeout()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, _content, _opts}, _from, %{status: :streaming} = state) do
    {:reply, {:error, :already_streaming}, state}
  end

  def handle_call({:send_message, content, opts}, _from, state) do
    thread = Chat.get_thread!(state.thread_id)
    thread_personas = Chat.thread_personas_for_thread(state.thread_id)
    is_group = length(thread_personas) > 1

    # Create user message
    {:ok, user_msg} =
      Chat.create_message(state.thread_id, %{role: "user", content: content})

    # Auto-title from first message (skip for general channels)
    now = DateTime.utc_now()

    title =
      cond do
        thread.type == "general" -> thread.title
        is_nil(thread.title) -> String.slice(content, 0..79)
        true -> thread.title
      end

    {:ok, updated_thread} = Chat.update_thread(thread, %{last_message_at: now, title: title})

    broadcast_thread(state.thread_id, {:new_message, user_msg})

    broadcast_global(
      {:thread_updated, Jarvis.Repo.preload(updated_thread, thread_personas: :persona)}
    )

    # Read thread settings from metadata
    collaboration = get_in(thread.metadata, ["collaboration"]) == true

    # Load project context + decisions if thread belongs to a project
    project_context =
      if thread.project_id do
        project = Jarvis.Projects.get_project!(thread.project_id)
        decisions = Jarvis.Projects.decisions_context(thread.project_id)

        parts =
          [
            project.context,
            if(decisions, do: "## Key Decisions\n\n#{decisions}")
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&(&1 == ""))

        if parts != [], do: Enum.join(parts, "\n\n"), else: nil
      end

    # Build persona queue — optionally filtered by persona_ids (for @mentions)
    filter_ids = Keyword.get(opts, :persona_ids)

    filtered_tps =
      if filter_ids do
        Enum.filter(thread_personas, fn tp -> tp.persona_id in filter_ids end)
      else
        thread_personas
      end

    filtered_group = length(filtered_tps) > 1

    persona_queue =
      Enum.map(filtered_tps, fn tp ->
        p = tp.persona
        model = if is_group, do: p.group_model || p.model, else: p.model

        %{
          id: p.id,
          name: p.name,
          model: model,
          system_prompt: p.system_prompt,
          thinking: p.thinking,
          group: filtered_group,
          paths: tp.paths || [],
          allowed_tools: tp.allowed_tools || []
        }
      end)

    # Guard: if filtering left no personas, bail out
    if persona_queue == [] do
      broadcast_status(state.thread_id, :idle)
      {:reply, {:error, :no_matching_agents}, state}
    else
      cancel_timer(state.idle_timer)

      new_state = %{
        state
        | status: :streaming,
          pending_personas: persona_queue,
          all_personas: persona_queue,
          project_context: project_context,
          buffer: "",
          ollama_history: [],
          tool_round: 0,
          collaboration: collaboration && filtered_group,
          current_round: 1,
          done_signaled: false,
          idle_timer: nil
      }

      new_state = start_next_persona(new_state)

      Chat.update_thread_status(state.thread_id, "active")
      broadcast_status(state.thread_id, :streaming)
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:stop_streaming, _from, %{status: :streaming} = state) do
    # Persist whatever has been streamed so far
    if state.current_message_id do
      message = Chat.get_message!(state.current_message_id)
      content = if state.buffer == "", do: "[Stopped]", else: state.buffer <> "\n\n*[Stopped]*"
      Chat.update_message(message, %{content: content})
      broadcast_thread(state.thread_id, {:message_replace, state.current_message_id, content})
      broadcast_thread(state.thread_id, {:message_complete, state.current_message_id})
    end

    Chat.update_thread_status(state.thread_id, "idle")
    broadcast_status(state.thread_id, :idle)
    {:reply, :ok, reset_state(state, :idle)}
  end

  def handle_call(:stop_streaming, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  # Ignore orphaned Ollama messages after stop
  def handle_info({:ollama_chunk, _}, %{status: s} = state) when s != :streaming,
    do: {:noreply, state}

  def handle_info({:ollama_tool_calls, _}, %{status: s} = state) when s != :streaming,
    do: {:noreply, state}

  def handle_info(:ollama_done, %{status: s} = state) when s != :streaming, do: {:noreply, state}

  def handle_info({:ollama_error, _}, %{status: s} = state) when s != :streaming,
    do: {:noreply, state}

  def handle_info({:ollama_chunk, content}, state) do
    new_buffer = state.buffer <> content
    broadcast_thread(state.thread_id, {:message_delta, state.current_message_id, content})
    {:noreply, %{state | buffer: new_buffer}}
  end

  def handle_info({:ollama_tool_calls, tool_calls}, state) do
    persona = state.current_persona
    Logger.info("Tool calls from #{persona.name}: #{inspect(tool_calls)}")

    results =
      Enum.map(tool_calls, fn tc ->
        func = tc["function"]
        name = func["name"]
        args = func["arguments"] || %{}

        broadcast_thread(state.thread_id, {:tool_use, state.current_message_id, name, args})

        tool_label = "\n\n`> #{name}(#{summarize_args(args)})`\n"
        broadcast_thread(state.thread_id, {:message_delta, state.current_message_id, tool_label})

        case Tools.execute(name, args, state.current_persona.paths) do
          {:ok, result} ->
            result_preview = String.slice(result, 0..200)
            suffix = if String.length(result) > 200, do: "...", else: ""

            broadcast_thread(
              state.thread_id,
              {:message_delta, state.current_message_id, "`#{result_preview}#{suffix}`\n"}
            )

            %{tool_call: tc, result: result}

          {:error, reason} ->
            broadcast_thread(
              state.thread_id,
              {:message_delta, state.current_message_id, "`Error: #{reason}`\n"}
            )

            %{tool_call: tc, result: "Error: #{reason}"}
        end
      end)

    tool_display =
      Enum.map_join(results, "", fn r ->
        func = r.tool_call["function"]
        name = func["name"]
        args = func["arguments"] || %{}
        result_preview = String.slice(r.result, 0..200)
        suffix = if String.length(r.result) > 200, do: "...", else: ""
        "\n\n`> #{name}(#{summarize_args(args)})`\n`#{result_preview}#{suffix}`\n"
      end)

    new_buffer = state.buffer <> tool_display

    assistant_tool_msg = %{
      role: "assistant",
      content: "",
      tool_calls:
        Enum.map(tool_calls, fn tc ->
          %{
            function: %{
              name: tc["function"]["name"],
              arguments: tc["function"]["arguments"] || %{}
            }
          }
        end)
    }

    tool_result_msgs =
      Enum.map(results, fn r ->
        %{role: "tool", content: r.result, tool_name: r.tool_call["function"]["name"]}
      end)

    new_history = state.ollama_history ++ [assistant_tool_msg | tool_result_msgs]
    new_round = state.tool_round + 1

    if new_round >= @max_tool_rounds do
      overflow_msg = "\n\n*[Tool call limit reached]*"
      broadcast_thread(state.thread_id, {:message_delta, state.current_message_id, overflow_msg})

      finalize_persona_turn(%{
        state
        | buffer: new_buffer <> overflow_msg,
          ollama_history: new_history,
          tool_round: new_round
      })
    else
      Jarvis.LLM.provider().stream_chat(
        self(),
        new_history,
        state.current_persona.model,
        tools:
          Tools.definitions(
            state.current_persona.paths,
            state.current_persona[:allowed_tools] || []
          ),
        think: state.current_persona.thinking
      )

      {:noreply,
       %{state | buffer: new_buffer, ollama_history: new_history, tool_round: new_round}}
    end
  end

  def handle_info(:ollama_done, state) do
    # Check if this persona signaled [DONE]
    done_signaled = String.contains?(state.buffer, @done_signal)

    # Strip [DONE] from the displayed/persisted content
    clean_buffer =
      state.buffer
      |> String.replace(@done_signal, "")
      |> String.trim()

    # Update the displayed message to remove [DONE] if it was streamed
    if done_signaled && state.buffer != clean_buffer do
      broadcast_thread(
        state.thread_id,
        {:message_replace, state.current_message_id, clean_buffer}
      )
    end

    finalize_persona_turn(%{state | buffer: clean_buffer, done_signaled: done_signaled})
  end

  def handle_info({:ollama_error, reason}, state) do
    Logger.error("Ollama error for thread #{state.thread_id}: #{inspect(reason)}")

    if state.current_message_id do
      message = Chat.get_message!(state.current_message_id)

      error_content =
        if state.buffer != "",
          do: state.buffer <> "\n\n[Error: #{inspect(reason)}]",
          else: "Error: #{inspect(reason)}"

      Chat.update_message(message, %{content: error_content})
    end

    broadcast_thread(state.thread_id, {:message_error, state.current_message_id, reason})
    Chat.update_thread_status(state.thread_id, "error")
    broadcast_status(state.thread_id, :error)

    {:noreply, reset_state(state, :error)}
  end

  def handle_info(:idle_timeout, %{status: :idle} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state) do
    {:noreply, %{state | idle_timer: schedule_idle_timeout()}}
  end

  # --- Helpers ---

  defp finalize_persona_turn(state) do
    # Persist the completed message
    if state.current_message_id do
      message = Chat.get_message!(state.current_message_id)
      Chat.update_message(message, %{content: state.buffer})
    end

    broadcast_thread(state.thread_id, {:message_complete, state.current_message_id})

    cond do
      # More personas queued in the current round
      state.pending_personas != [] ->
        new_state = %{
          state
          | buffer: "",
            current_message_id: nil,
            current_persona: nil,
            ollama_history: [],
            tool_round: 0
        }

        new_state = start_next_persona(new_state)
        {:noreply, new_state}

      # Collaboration mode: check if we should start another round
      state.collaboration && !state.done_signaled &&
          state.current_round < @max_collaboration_rounds ->
        next_round = state.current_round + 1
        Logger.info("Collaboration round #{next_round} for thread #{state.thread_id}")
        broadcast_thread(state.thread_id, {:collaboration_round, next_round})

        new_state = %{
          state
          | pending_personas: state.all_personas,
            current_round: next_round,
            buffer: "",
            current_message_id: nil,
            current_persona: nil,
            ollama_history: [],
            tool_round: 0,
            done_signaled: false
        }

        new_state = start_next_persona(new_state)
        {:noreply, new_state}

      # Collaboration hit max rounds
      state.collaboration && !state.done_signaled &&
          state.current_round >= @max_collaboration_rounds ->
        Logger.info("Collaboration max rounds reached for thread #{state.thread_id}")
        finish_streaming(state)

      # All done (single round, or collaboration concluded)
      true ->
        finish_streaming(state)
    end
  end

  defp finish_streaming(state) do
    thread = Chat.get_thread!(state.thread_id)
    {:ok, updated_thread} = Chat.update_thread(thread, %{last_message_at: DateTime.utc_now()})

    # Generate thread summary asynchronously (non-blocking)
    maybe_generate_summary(state.thread_id)

    # Agent just responded — thread is now waiting for user input
    Chat.update_thread_status(state.thread_id, "waiting")
    broadcast_status(state.thread_id, :idle)
    broadcast_global({:thread_updated, updated_thread})

    {:noreply, reset_state(state, :idle)}
  end

  defp maybe_generate_summary(thread_id) do
    # Generate a summary asynchronously — don't block the streaming flow
    Task.start(fn ->
      try do
        messages = Chat.list_messages(thread_id)

        # Only summarize threads with enough content
        if length(messages) >= 4 do
          recent =
            messages
            |> Enum.take(-10)
            |> Enum.map(fn msg ->
              name = if msg.persona, do: msg.persona.name, else: "User"
              "#{name}: #{String.slice(msg.content || "", 0..300)}"
            end)
            |> Enum.join("\n")

          prompt = [
            %{
              role: "system",
              content:
                "Summarize this conversation in 1-2 sentences. Focus on what was decided or accomplished, not the back-and-forth. Be concise."
            },
            %{role: "user", content: recent}
          ]

          llm = Jarvis.LLM.provider()

          case llm.chat(prompt, llm.default_model()) do
            {:ok, summary} ->
              thread = Chat.get_thread!(thread_id)
              Chat.update_thread(thread, %{summary: String.trim(summary)})

            {:error, reason} ->
              Logger.warning(
                "Failed to generate summary for thread #{thread_id}: #{inspect(reason)}"
              )
          end
        end
      rescue
        e ->
          Logger.warning(
            "Summary generation failed for thread #{thread_id}: #{Exception.message(e)}"
          )
      end
    end)
  end

  @impl true
  def terminate(:normal, _state), do: :ok
  def terminate(:shutdown, _state), do: :ok

  def terminate(reason, %{status: :streaming, thread_id: thread_id} = state) do
    Logger.error("ThreadServer #{thread_id} crashed while streaming: #{inspect(reason)}")

    # Persist whatever was streamed so far
    if state.current_message_id do
      message = Chat.get_message!(state.current_message_id)

      content =
        if state.buffer == "",
          do: "[Error: process crashed]",
          else: state.buffer <> "\n\n*[Error: process crashed]*"

      Chat.update_message(message, %{content: content})
    end

    # Mark thread as error so it's not stuck "active" forever
    Chat.update_thread_status(thread_id, "error")
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp reset_state(state, status) do
    %{
      state
      | status: status,
        current_message_id: nil,
        current_persona: nil,
        pending_personas: [],
        all_personas: [],
        buffer: "",
        ollama_history: [],
        tool_round: 0,
        collaboration: false,
        current_round: 1,
        done_signaled: false,
        idle_timer: schedule_idle_timeout()
    }
  end

  defp start_next_persona(%{pending_personas: [persona | rest]} = state) do
    {:ok, assistant_msg} =
      Chat.create_message(state.thread_id, %{
        role: "assistant",
        content: "",
        model: persona.model,
        persona_id: persona.id
      })

    broadcast_thread(state.thread_id, {:new_message, assistant_msg})
    broadcast_thread(state.thread_id, {:streaming_persona, persona.id, persona.name})

    other_names =
      state.all_personas
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 == persona.name))

    ollama_history =
      state.thread_id
      |> Chat.messages_for_ollama(persona.system_prompt,
        group: persona.group,
        collaboration: state.collaboration,
        current_persona_name: persona.name,
        round: state.current_round,
        other_persona_names: other_names,
        project_context: state.project_context,
        max_tokens: Jarvis.Models.message_budget(persona.model)
      )
      |> Enum.reject(fn m -> m.content == "" and m.role == "assistant" end)

    Jarvis.LLM.provider().stream_chat(
      self(),
      ollama_history,
      persona.model,
      tools: Tools.definitions(persona.paths, persona[:allowed_tools] || []),
      think: persona.thinking
    )

    %{
      state
      | pending_personas: rest,
        current_message_id: assistant_msg.id,
        current_persona: persona,
        buffer: "",
        ollama_history: ollama_history,
        tool_round: 0
    }
  end

  defp start_next_persona(%{pending_personas: []} = state), do: state

  defp summarize_args(args) when map_size(args) == 0, do: ""

  defp summarize_args(args) do
    args
    |> Enum.map(fn {k, v} ->
      val = String.slice(to_string(v), 0..40)
      "#{k}: #{val}#{if String.length(to_string(v)) > 40, do: "...", else: ""}"
    end)
    |> Enum.join(", ")
  end

  defp broadcast_thread(thread_id, message) do
    PubSub.broadcast(Jarvis.PubSub, "thread:#{thread_id}", message)
  end

  defp broadcast_global(message) do
    PubSub.broadcast(Jarvis.PubSub, "threads", message)
  end

  defp broadcast_status(thread_id, status) do
    broadcast_global({:thread_status, thread_id, status})
    broadcast_thread(thread_id, {:status_changed, status})
  end

  defp schedule_idle_timeout do
    Process.send_after(self(), :idle_timeout, @idle_timeout)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
