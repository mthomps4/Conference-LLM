defmodule Jarvis.Repo.Migrations.AddContextToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :context, :text
    end
  end
end
