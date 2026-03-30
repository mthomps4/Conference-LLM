defmodule Jarvis.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :role, :string
    field :content, :string, default: ""
    field :model, :string
    field :token_count, :integer
    field :metadata, :map, default: %{}

    belongs_to :thread, Jarvis.Chat.Thread
    belongs_to :persona, Jarvis.Chat.Persona

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:role, :content, :model, :token_count, :metadata, :persona_id])
    |> validate_required([:role])
    |> validate_inclusion(:role, ~w(system user assistant))
  end
end
