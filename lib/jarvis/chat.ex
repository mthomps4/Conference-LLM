defmodule Jarvis.Chat do
  @moduledoc """
  Context for managing personas, conversation threads, and messages.
  """
  import Ecto.Query
  alias Jarvis.Repo
  alias Jarvis.Chat.{Persona, Thread, ThreadPersona, Message}

  # --- Personas ---

  def list_personas do
    Persona
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def get_persona!(id), do: Repo.get!(Persona, id)

  def create_persona(attrs) do
    %Persona{}
    |> Persona.changeset(attrs)
    |> Repo.insert()
  end

  def update_persona(%Persona{} = persona, attrs) do
    persona
    |> Persona.changeset(attrs)
    |> Repo.update()
  end

  def delete_persona(%Persona{} = persona) do
    Repo.delete(persona)
  end

  def change_persona(%Persona{} = persona, attrs \\ %{}) do
    Persona.changeset(persona, attrs)
  end

  # --- Threads ---

  @doc """
  Creates a thread with one or more personas.
  Accepts a single persona_id or a list of persona_ids.
  """
  def create_thread(persona_ids, attrs \\ %{})

  def create_thread(persona_id, attrs) when is_integer(persona_id) do
    create_thread([persona_id], attrs)
  end

  def create_thread(persona_ids, attrs) when is_list(persona_ids) do
    Repo.transaction(fn ->
      case %Thread{} |> Thread.changeset(attrs) |> Repo.insert() do
        {:ok, thread} ->
          persona_ids
          |> Enum.with_index()
          |> Enum.each(fn {pid, idx} ->
            %ThreadPersona{thread_id: thread.id, persona_id: pid, position: idx}
            |> Repo.insert!()
          end)

          thread
          |> Repo.preload(thread_personas: :persona)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def list_threads do
    Thread
    |> order_by([t], desc_nulls_last: t.last_message_at, desc: t.inserted_at)
    |> preload(thread_personas: :persona)
    |> Repo.all()
  end

  def get_thread!(id) do
    Thread
    |> preload(thread_personas: :persona)
    |> Repo.get!(id)
  end

  def update_thread(%Thread{} = thread, attrs) do
    thread
    |> Thread.changeset(attrs)
    |> Repo.update()
  end

  def delete_thread(%Thread{} = thread) do
    Repo.delete(thread)
  end

  @doc """
  Returns personas for a thread in position order.
  """
  def personas_for_thread(thread_id) do
    ThreadPersona
    |> where(thread_id: ^thread_id)
    |> order_by(asc: :position)
    |> preload(:persona)
    |> Repo.all()
    |> Enum.map(& &1.persona)
  end

  @doc """
  Returns thread_persona records (with persona preloaded) in position order.
  Includes per-persona paths.
  """
  def thread_personas_for_thread(thread_id) do
    ThreadPersona
    |> where(thread_id: ^thread_id)
    |> order_by(asc: :position)
    |> preload(:persona)
    |> Repo.all()
  end

  def update_thread_persona(%ThreadPersona{} = tp, attrs) do
    tp
    |> ThreadPersona.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns :direct for single-persona threads, :group for multi-persona.
  """
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

  @doc """
  Returns messages formatted for the Ollama API.

  Options:
    - `:group` — whether this is a group chat
    - `:collaboration` — whether collaboration mode is active
    - `:current_persona_name` — name of the persona about to respond
    - `:round` — current discussion round (1 = initial, 2+ = follow-up)
    - `:other_persona_names` — names of other personas in the group
  """
  def messages_for_ollama(thread_id, system_prompt \\ nil, opts \\ []) do
    is_group = Keyword.get(opts, :group, false)
    collaboration = Keyword.get(opts, :collaboration, false)
    current_name = Keyword.get(opts, :current_persona_name)
    round = Keyword.get(opts, :round, 1)
    other_names = Keyword.get(opts, :other_persona_names, [])

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

    system =
      build_system_prompt(system_prompt, %{
        group: is_group,
        collaboration: collaboration,
        name: current_name,
        round: round,
        others: other_names
      })

    if system do
      [%{role: "system", content: system} | history]
    else
      history
    end
  end

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
