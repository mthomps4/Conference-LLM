defmodule Jarvis.Repo.Migrations.CreateThreadsAndMessages do
  use Ecto.Migration

  def change do
    create table(:personas) do
      add :name, :text, null: false
      add :model, :text, null: false
      add :system_prompt, :text
      add :description, :text
      add :color, :text, null: false, default: "#6366f1"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create table(:threads) do
      add :persona_id, references(:personas, on_delete: :delete_all), null: false
      add :title, :text
      add :last_message_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threads, [:persona_id])
    create index(:threads, [:last_message_at])

    create table(:messages) do
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      add :role, :text, null: false
      add :content, :text, null: false, default: ""
      add :model, :text
      add :token_count, :integer
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:thread_id])
    create index(:messages, [:thread_id, :inserted_at])
  end
end
