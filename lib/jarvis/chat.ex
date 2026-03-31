defmodule Jarvis.Chat do
  @moduledoc """
  Context for threads, messages, and thread-level operations.
  Persona CRUD has moved to Jarvis.Agents.
  Project CRUD has moved to Jarvis.Projects.
  """
  import Ecto.Query
  alias Jarvis.Repo
  alias Jarvis.Chat.{Thread, ThreadPersona, Message}

  # --- Threads ---

  def list_threads_for_project(project_id) do
    Thread
    |> where(project_id: ^project_id)
    |> where([t], t.status != "archived")
    |> order_by([t], desc: fragment("type = 'general'"), desc_nulls_last: t.last_message_at)
    |> preload(thread_personas: :persona)
    |> Repo.all()
  end

  def list_inbox_threads do
    Thread
    |> where([t], is_nil(t.project_id))
    |> where([t], t.status != "archived")
    |> order_by([t], desc_nulls_last: t.last_message_at, desc: t.inserted_at)
    |> preload(thread_personas: :persona)
    |> Repo.all()
  end

  def get_thread!(id) do
    Thread
    |> preload(thread_personas: :persona)
    |> Repo.get!(id)
  end

  def create_thread(attrs) do
    %Thread{}
    |> Thread.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, thread} -> {:ok, Repo.preload(thread, thread_personas: :persona)}
      error -> error
    end
  end

  @doc """
  Creates a thread within a project, attaching the given persona IDs.
  """
  def create_thread_in_project(project_id, persona_ids, attrs \\ %{}) do
    Repo.transaction(fn ->
      thread_attrs = Map.merge(attrs, %{project_id: project_id, type: "thread"})

      case %Thread{} |> Thread.changeset(thread_attrs) |> Repo.insert() do
        {:ok, thread} ->
          persona_ids
          |> Enum.with_index()
          |> Enum.each(fn {pid, idx} ->
            %ThreadPersona{thread_id: thread.id, persona_id: pid, position: idx}
            |> Repo.insert!()
          end)

          thread = Repo.preload(thread, thread_personas: :persona)
          Phoenix.PubSub.broadcast(Jarvis.PubSub, "threads", {:thread_created, thread})
          thread

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_thread(%Thread{} = thread, attrs) do
    thread
    |> Thread.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates thread status in DB. Broadcasting is handled by the caller (ThreadServer).
  """
  def update_thread_status(thread_id, status) do
    thread = Repo.get!(Thread, thread_id)
    update_thread(thread, %{status: status})
  end

  def archive_thread(%Thread{} = thread) do
    update_thread(thread, %{status: "archived"})
  end

  def delete_thread(%Thread{} = thread) do
    case Repo.delete(thread) do
      {:ok, deleted} ->
        Phoenix.PubSub.broadcast(Jarvis.PubSub, "threads", {:thread_deleted, deleted.id})
        {:ok, deleted}

      error ->
        error
    end
  end

  # --- Thread Personas ---

  def personas_for_thread(thread_id) do
    ThreadPersona
    |> where(thread_id: ^thread_id)
    |> order_by(asc: :position)
    |> preload(:persona)
    |> Repo.all()
    |> Enum.map(& &1.persona)
  end

  def thread_personas_for_thread(thread_id) do
    ThreadPersona
    |> where(thread_id: ^thread_id)
    |> order_by(asc: :position)
    |> preload(:persona)
    |> Repo.all()
  end

  def add_persona_to_thread(thread_id, persona_id, opts \\ []) do
    max_pos =
      ThreadPersona
      |> where(thread_id: ^thread_id)
      |> select([tp], max(tp.position))
      |> Repo.one() || -1

    %ThreadPersona{
      thread_id: thread_id,
      persona_id: persona_id,
      position: max_pos + 1,
      paths: Keyword.get(opts, :paths, []),
      allowed_tools: Keyword.get(opts, :allowed_tools, [])
    }
    |> Repo.insert()
  end

  def remove_persona_from_thread(thread_id, persona_id) do
    ThreadPersona
    |> where(thread_id: ^thread_id, persona_id: ^persona_id)
    |> Repo.delete_all()
  end

  def update_thread_persona(%ThreadPersona{} = tp, attrs) do
    tp
    |> ThreadPersona.changeset(attrs)
    |> Repo.update()
  end

  def thread_type(%Thread{thread_personas: tps}) when is_list(tps) do
    if length(tps) > 1, do: :group, else: :direct
  end

  def thread_type(%Thread{} = thread) do
    thread |> Repo.preload(:thread_personas) |> thread_type()
  end

  # --- Messages ---

  def list_messages(thread_id) do
    Message
    |> where(thread_id: ^thread_id)
    |> order_by(asc: :inserted_at)
    |> preload(:persona)
    |> Repo.all()
  end

  def get_message!(id), do: Repo.get!(Message, id)

  def create_message(thread_id, attrs) do
    %Message{thread_id: thread_id}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, msg} -> {:ok, Repo.preload(msg, :persona)}
      error -> error
    end
  end

  def update_message(%Message{} = message, attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end

  # Default token budget (chars / 4 approximation). Configurable per call.
  # Conservative default for small models. Large models can pass higher values.
  @default_max_tokens 6000

  @doc """
  Returns messages formatted for the Ollama API.

  Options:
    - `:group` — whether this is a group chat
    - `:collaboration` — whether collaboration mode is active
    - `:current_persona_name` — name of the persona about to respond
    - `:round` — current discussion round (1 = initial, 2+ = follow-up)
    - `:other_persona_names` — names of other personas in the group
    - `:project_context` — project-level context string to inject into system prompt
    - `:max_tokens` — token budget for the message list (default #{@default_max_tokens})
  """
  def messages_for_ollama(thread_id, system_prompt \\ nil, opts \\ []) do
    is_group = Keyword.get(opts, :group, false)
    collaboration = Keyword.get(opts, :collaboration, false)
    current_name = Keyword.get(opts, :current_persona_name)
    round = Keyword.get(opts, :round, 1)
    other_names = Keyword.get(opts, :other_persona_names, [])
    project_context = Keyword.get(opts, :project_context)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    history =
      thread_id
      |> list_messages()
      |> Enum.map(fn msg ->
        content =
          if is_group && msg.role == "assistant" && msg.persona &&
               msg.persona.name != current_name do
            "[#{msg.persona.name}]: #{msg.content}"
          else
            msg.content
          end

        %{role: msg.role, content: content}
      end)

    # Build full system prompt: project context + persona prompt + group instructions
    full_prompt =
      build_full_system_prompt(system_prompt, project_context, %{
        group: is_group,
        collaboration: collaboration,
        name: current_name,
        round: round,
        others: other_names
      })

    # Apply token budget: system prompt first, then recent messages
    system_tokens = estimate_tokens(full_prompt || "")
    remaining = max(max_tokens - system_tokens, max_tokens |> div(2))
    trimmed_history = trim_to_budget(history, remaining)

    if full_prompt do
      [%{role: "system", content: full_prompt} | trimmed_history]
    else
      trimmed_history
    end
  end

  defp estimate_tokens(text) when is_binary(text), do: div(String.length(text), 4)
  defp estimate_tokens(_), do: 0

  defp trim_to_budget(messages, token_budget) do
    # Keep messages from the end (most recent), always keep the first message (user's initial request)
    {first, rest} =
      case messages do
        [first | rest] -> {first, rest}
        [] -> {nil, []}
      end

    if first == nil do
      []
    else
      first_tokens = estimate_tokens(first.content)
      remaining_budget = token_budget - first_tokens

      # Take messages from the end until we hit the budget
      {kept, _} =
        rest
        |> Enum.reverse()
        |> Enum.reduce({[], remaining_budget}, fn msg, {acc, budget} ->
          msg_tokens = estimate_tokens(msg.content)

          if budget - msg_tokens > 0 do
            {[msg | acc], budget - msg_tokens}
          else
            {acc, budget}
          end
        end)

      if kept == rest do
        # Everything fits
        [first | rest]
      else
        # Insert a truncation marker
        [
          first,
          %{role: "system", content: "[Earlier messages truncated for context window]"} | kept
        ]
      end
    end
  end

  defp build_full_system_prompt(persona_prompt, project_context, group_opts) do
    parts = [
      if(project_context && project_context != "",
        do: "## Project Context\n\n#{project_context}"
      ),
      build_system_prompt(persona_prompt, group_opts)
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # --- @Mention Parsing ---

  @doc """
  Extracts @PersonaName mentions from text.
  Returns {cleaned_text, [%Persona{}]} where cleaned_text has @mentions removed.
  """
  def parse_mentions(text, available_personas) do
    # Match @Name patterns (handles multi-word names in quotes or single-word names)
    regex = ~r/@"([^"]+)"|@(\S+)/

    mentions =
      Regex.scan(regex, text)
      |> Enum.flat_map(fn
        [_, quoted, ""] -> [quoted]
        [_, "", name] -> [name]
        [_, name] -> [name]
        _ -> []
      end)

    matched =
      mentions
      |> Enum.flat_map(fn mention ->
        Enum.filter(available_personas, fn p ->
          String.downcase(p.name) == String.downcase(mention)
        end)
      end)
      |> Enum.uniq_by(& &1.id)

    clean = Regex.replace(regex, text, "") |> String.trim()

    {clean, matched}
  end

  @doc """
  Returns thread IDs where the last message is from an assistant (awaiting user input).
  """
  def waiting_thread_ids do
    subquery =
      from(m in Message,
        distinct: m.thread_id,
        order_by: [desc: m.inserted_at],
        select: %{thread_id: m.thread_id, role: m.role}
      )

    from(s in subquery(subquery),
      where: s.role == "assistant",
      select: s.thread_id
    )
    |> Repo.all()
  end

  # --- Private ---

  defp build_system_prompt(nil, _), do: nil
  defp build_system_prompt("", _), do: nil

  defp build_system_prompt(base, %{group: false}), do: base

  defp build_system_prompt(base, %{group: true, collaboration: false, name: name}) do
    base <>
      "\n\nYou are in a group conversation with other AI participants. " <>
      "Respond ONLY as yourself (#{name}). " <>
      "Do NOT generate responses for other participants. " <>
      "Messages from others are prefixed with their name in brackets."
  end

  defp build_system_prompt(base, %{
         group: true,
         collaboration: true,
         name: name,
         round: round,
         others: others
       }) do
    others_str = Enum.join(others, ", ")

    round_instructions =
      if round <= 1 do
        "This is the opening round. Share your perspective on the user's request. " <>
          "You may address other participants directly by name."
      else
        "This is a follow-up round. Build on what others have said. " <>
          "You can agree, disagree, ask questions, or refine the group's position. " <>
          "If the group has reached a solid conclusion or you have nothing meaningful to add, " <>
          "end your message with exactly [DONE] on its own line."
      end

    base <>
      "\n\nYou are #{name} in a collaborative group discussion with: #{others_str}. " <>
      "Respond ONLY as yourself. Do NOT generate responses for other participants. " <>
      "Messages from others are prefixed with their name in brackets.\n\n" <>
      round_instructions
  end
end
