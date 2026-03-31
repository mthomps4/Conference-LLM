defmodule Jarvis.Chat.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(general thread)
  @statuses ~w(active waiting idle error archived)

  schema "threads" do
    field :title, :string
    field :type, :string, default: "thread"
    field :status, :string, default: "idle"
    field :summary, :string
    field :last_message_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :project, Jarvis.Projects.Project
    has_many :thread_personas, Jarvis.Chat.ThreadPersona, preload_order: [asc: :position]
    has_many :personas, through: [:thread_personas, :persona]
    has_many :messages, Jarvis.Chat.Message

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:title, :type, :status, :summary, :last_message_at, :metadata, :project_id])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
  end

  def types, do: @types
  def statuses, do: @statuses
end
