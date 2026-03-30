defmodule Jarvis.Repo.Migrations.AddGroupChatSupport do
  use Ecto.Migration

  def change do
    # 1. Create thread_personas join table
    create table(:thread_personas) do
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      add :persona_id, references(:personas, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:thread_personas, [:thread_id, :persona_id])
    create index(:thread_personas, [:thread_id, :position])

    # 2. Add persona_id to messages (nullable — nil for user messages)
    alter table(:messages) do
      add :persona_id, references(:personas, on_delete: :nilify_all)
    end

    create index(:messages, [:persona_id])

    # 3. Add label field to threads for group chat labels
    alter table(:threads) do
      add :label, :text
    end

    # 4. Data migration: copy existing threads.persona_id → thread_personas
    execute(
      """
      INSERT INTO thread_personas (thread_id, persona_id, position, inserted_at)
      SELECT id, persona_id, 0, now()
      FROM threads
      WHERE persona_id IS NOT NULL
      """,
      # Rollback: no-op (we'll re-add persona_id to threads)
      "SELECT 1"
    )

    # 5. Drop persona_id from threads
    alter table(:threads) do
      remove :persona_id, references(:personas, on_delete: :delete_all), null: false
    end
  end
end
