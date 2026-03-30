defmodule Jarvis.Chat.ThreadPersona do
  use Ecto.Schema
  import Ecto.Changeset

  schema "thread_personas" do
    field :position, :integer, default: 0
    field :paths, {:array, :string}, default: []

    belongs_to :thread, Jarvis.Chat.Thread
    belongs_to :persona, Jarvis.Chat.Persona

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(thread_persona, attrs) do
    thread_persona
    |> cast(attrs, [:position, :paths])
    |> validate_required([:thread_id, :persona_id])
  end
end
