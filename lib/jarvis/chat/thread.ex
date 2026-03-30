defmodule Jarvis.Chat.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  schema "threads" do
    field :title, :string
    field :label, :string
    field :last_message_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    has_many :thread_personas, Jarvis.Chat.ThreadPersona, preload_order: [asc: :position]
    has_many :personas, through: [:thread_personas, :persona]
    has_many :messages, Jarvis.Chat.Message

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:title, :label, :last_message_at, :metadata])
  end
end
