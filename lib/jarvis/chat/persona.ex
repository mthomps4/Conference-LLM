defmodule Jarvis.Chat.Persona do
  use Ecto.Schema
  import Ecto.Changeset

  @colors [
    {"Slate", "#64748b"},
    {"Rose", "#f43f5e"},
    {"Orange", "#f97316"},
    {"Amber", "#f59e0b"},
    {"Emerald", "#10b981"},
    {"Teal", "#14b8a6"},
    {"Cyan", "#06b6d4"},
    {"Indigo", "#6366f1"},
    {"Purple", "#a855f7"},
    {"Pink", "#ec4899"}
  ]

  schema "personas" do
    field :name, :string
    field :model, :string
    field :group_model, :string
    field :thinking, :boolean, default: true
    field :system_prompt, :string
    field :description, :string
    field :color, :string, default: "#6366f1"
    field :metadata, :map, default: %{}

    has_many :thread_personas, Jarvis.Chat.ThreadPersona
    has_many :threads, through: [:thread_personas, :thread]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [:name, :model, :group_model, :thinking, :system_prompt, :description, :color, :metadata])
    |> validate_required([:name, :model, :color])
  end

  def colors, do: @colors
end
