defmodule Jarvis.Repo.Migrations.AddProjectSupportToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :project_id, references(:projects, on_delete: :delete_all)
      add :type, :text, null: false, default: "thread"
      add :status, :text, null: false, default: "idle"
      remove :label, :text
    end

    create index(:threads, [:project_id])
    create index(:threads, [:status])

    create unique_index(:threads, [:project_id],
             where: "type = 'general'",
             name: :threads_one_general_per_project
           )
  end
end
