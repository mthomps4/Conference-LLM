defmodule Jarvis.Agents do
  @moduledoc """
  Context for managing AI agent personas.
  """
  import Ecto.Query
  alias Jarvis.Repo
  alias Jarvis.Chat.Persona

  def list_agents do
    Persona
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def get_agent!(id), do: Repo.get!(Persona, id)

  def create_agent(attrs) do
    %Persona{}
    |> Persona.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%Persona{} = persona, attrs) do
    persona
    |> Persona.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%Persona{} = persona) do
    Repo.delete(persona)
  end

  def change_agent(%Persona{} = persona, attrs \\ %{}) do
    Persona.changeset(persona, attrs)
  end
end
