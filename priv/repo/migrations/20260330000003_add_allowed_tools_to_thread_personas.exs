defmodule Jarvis.Repo.Migrations.AddAllowedToolsToThreadPersonas do
  use Ecto.Migration

  def change do
    alter table(:thread_personas) do
      add :allowed_tools, {:array, :text}, null: false, default: []
    end
  end
end
