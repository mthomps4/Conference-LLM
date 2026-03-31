defmodule Jarvis.Projects do
  @moduledoc """
  Context for managing projects — the top-level organizational unit.
  Each project gets an auto-created #general channel.
  """
  import Ecto.Query
  alias Jarvis.Repo
  alias Jarvis.Projects.{Project, Decision}
  alias Jarvis.Chat.{Thread, ThreadPersona}

  def list_projects do
    Project
    |> where([p], is_nil(p.archived_at))
    |> order_by(asc: :name)
    |> preload(threads: [thread_personas: :persona])
    |> Repo.all()
  end

  def get_project!(id) do
    Project
    |> preload(threads: ^threads_query())
    |> Repo.get!(id)
  end

  defp threads_query do
    Thread
    |> where([t], t.status != "archived")
    |> order_by([t], desc: fragment("type = 'general'"), desc_nulls_last: t.last_message_at)
    |> preload(thread_personas: :persona)
  end

  def create_project(attrs) do
    Repo.transaction(fn ->
      case %Project{} |> Project.changeset(attrs) |> Repo.insert() do
        {:ok, project} ->
          {:ok, _general} =
            %Thread{project_id: project.id, type: "general", title: "#general"}
            |> Repo.insert()

          Repo.preload(project, threads: [thread_personas: :persona])

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def archive_project(%Project{} = project) do
    Repo.transaction(fn ->
      {:ok, project} = update_project(project, %{archived_at: DateTime.utc_now()})

      threads =
        Thread
        |> where(project_id: ^project.id)
        |> Repo.all()

      for thread <- threads do
        Jarvis.Chat.update_thread_status(thread.id, "archived")
        Phoenix.PubSub.broadcast(Jarvis.PubSub, "threads", {:thread_status, thread.id, :idle})
      end

      project
    end)
  end

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end

  @doc """
  Returns the general channel thread for a project.
  """
  def general_channel(project_id) do
    Thread
    |> where(project_id: ^project_id, type: "general")
    |> preload(thread_personas: :persona)
    |> Repo.one()
  end

  @doc """
  Adds an agent to a project's general channel.
  """
  def add_agent_to_project(project_id, persona_id, opts \\ []) do
    general = general_channel(project_id)

    max_pos =
      ThreadPersona
      |> where(thread_id: ^general.id)
      |> select([tp], max(tp.position))
      |> Repo.one() || -1

    %ThreadPersona{
      thread_id: general.id,
      persona_id: persona_id,
      position: max_pos + 1,
      paths: Keyword.get(opts, :paths, []),
      allowed_tools: Keyword.get(opts, :allowed_tools, [])
    }
    |> Repo.insert()
  end

  def remove_agent_from_project(project_id, persona_id) do
    general = general_channel(project_id)

    ThreadPersona
    |> where(thread_id: ^general.id, persona_id: ^persona_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns personas attached to a project's general channel.
  """
  def project_agents(project_id) do
    general = general_channel(project_id)

    if general do
      ThreadPersona
      |> where(thread_id: ^general.id)
      |> order_by(asc: :position)
      |> preload(:persona)
      |> Repo.all()
      |> Enum.map(& &1.persona)
    else
      []
    end
  end

  # --- Decisions ---

  @doc """
  Returns all decisions for a project, most recent first.
  """
  def list_decisions(project_id) do
    Decision
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Adds a decision to a project's log.
  """
  def add_decision(project_id, attrs) do
    %Decision{project_id: project_id}
    |> Decision.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Removes a decision.
  """
  def delete_decision(decision_id) do
    Repo.get!(Decision, decision_id) |> Repo.delete()
  end

  @doc """
  Returns decisions formatted as a string for injection into agent context.
  """
  def decisions_context(project_id) do
    decisions = list_decisions(project_id)

    if decisions == [] do
      nil
    else
      decisions
      |> Enum.reverse()
      |> Enum.map(fn d ->
        date = Calendar.strftime(d.inserted_at, "%Y-%m-%d")
        by = if d.decided_by, do: " (#{d.decided_by})", else: ""
        "- [#{date}#{by}] #{d.content}"
      end)
      |> Enum.join("\n")
    end
  end
end
