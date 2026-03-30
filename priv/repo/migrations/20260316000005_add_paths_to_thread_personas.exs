defmodule Jarvis.Repo.Migrations.AddPathsToThreadPersonas do
  use Ecto.Migration

  def change do
    alter table(:thread_personas) do
      add :paths, {:array, :text}, null: false, default: []
    end

    # Migrate existing thread-level tools_base_path to per-persona paths
    execute(
      """
      UPDATE thread_personas tp
      SET paths = ARRAY[threads.metadata->>'tools_base_path']
      FROM threads
      WHERE tp.thread_id = threads.id
        AND threads.metadata->>'tools_base_path' IS NOT NULL
        AND threads.metadata->>'tools_base_path' != ''
      """,
      "SELECT 1"
    )
  end
end
