defmodule Jarvis.Repo.Migrations.AddThinkingToPersonas do
  use Ecto.Migration

  def change do
    alter table(:personas) do
      add :thinking, :boolean, null: false, default: true
    end
  end
end
