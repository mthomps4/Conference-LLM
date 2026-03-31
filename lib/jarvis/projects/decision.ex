defmodule Jarvis.Projects.Decision do
  @moduledoc """
  A project-level decision. Append-only log of key decisions made across
  any thread in a project. Visible to all agents in all threads.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "decisions" do
    field :content, :string
    field :decided_by, :string
    field :metadata, :map, default: %{}

    belongs_to :project, Jarvis.Projects.Project
    belongs_to :thread, Jarvis.Chat.Thread

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:content, :decided_by, :project_id, :thread_id, :metadata])
    |> validate_required([:content, :project_id])
  end
end
