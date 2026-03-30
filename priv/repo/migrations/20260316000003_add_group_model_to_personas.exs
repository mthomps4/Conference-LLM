defmodule Jarvis.Repo.Migrations.AddGroupModelToPersonas do
  use Ecto.Migration

  def change do
    alter table(:personas) do
      add :group_model, :text
    end
  end
end
