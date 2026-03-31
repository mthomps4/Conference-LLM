defmodule Jarvis.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :description, :string
    field :context, :string
    field :color, :string, default: "#6366f1"
    field :archived_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    has_many :threads, Jarvis.Chat.Thread

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description, :context, :color, :archived_at, :metadata])
    |> validate_required([:name, :color])
  end
end
