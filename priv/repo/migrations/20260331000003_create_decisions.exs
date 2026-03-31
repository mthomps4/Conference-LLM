defmodule Jarvis.Repo.Migrations.CreateDecisions do
  use Ecto.Migration

  def change do
    create table(:decisions) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :thread_id, references(:threads, on_delete: :nilify_all)
      add :content, :text, null: false
      add :decided_by, :text
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:decisions, [:project_id])
    create index(:decisions, [:inserted_at])
  end
end
