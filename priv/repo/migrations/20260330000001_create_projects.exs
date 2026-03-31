defmodule Jarvis.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :name, :text, null: false
      add :description, :text
      add :color, :text, null: false, default: "#6366f1"
      add :archived_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:projects, [:archived_at])
  end
end
