defmodule Jarvis.Repo.Migrations.AddSummaryToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :summary, :text
    end
  end
end
