defmodule JarvisWeb.PersonaLive do
  use JarvisWeb, :live_view

  alias Jarvis.Chat
  alias Jarvis.Chat.Persona

  @impl true
  def mount(_params, _session, socket) do
    models =
      case Jarvis.Ollama.list_models() do
        {:ok, m} -> m
        _ -> [Jarvis.Ollama.default_model()]
      end

    {:ok, assign(socket, models: models, personas: Chat.list_personas())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, persona: nil, form: nil, page_title: "Contacts")
  end

  defp apply_action(socket, :new, _params) do
    persona = %Persona{color: "#6366f1"}
    changeset = Chat.change_persona(persona)

    assign(socket,
      persona: persona,
      form: to_form(changeset),
      page_title: "New Contact"
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    persona = Chat.get_persona!(id)
    changeset = Chat.change_persona(persona)

    assign(socket,
      persona: persona,
      form: to_form(changeset),
      page_title: "Edit #{persona.name}"
    )
  end

  # --- Events ---

  @impl true
  def handle_event("validate", %{"persona" => params}, socket) do
    changeset =
      socket.assigns.persona
      |> Chat.change_persona(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"persona" => params}, socket) do
    save_persona(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    persona = Chat.get_persona!(id)
    {:ok, _} = Chat.delete_persona(persona)
    personas = Enum.reject(socket.assigns.personas, &(&1.id == persona.id))

    {:noreply,
     socket
     |> assign(personas: personas)
     |> put_flash(:info, "#{persona.name} deleted")}
  end

  defp save_persona(socket, :new, params) do
    case Chat.create_persona(params) do
      {:ok, _persona} ->
        {:noreply,
         socket
         |> put_flash(:info, "Contact created")
         |> push_navigate(to: ~p"/contacts")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_persona(socket, :edit, params) do
    case Chat.update_persona(socket.assigns.persona, params) do
      {:ok, _persona} ->
        {:noreply,
         socket
         |> put_flash(:info, "Contact updated")
         |> push_navigate(to: ~p"/contacts")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # --- Helpers ---

  defp initials(name) when is_binary(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Index --%>
      <div :if={@live_action == :index} class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">Contacts</h1>
            <p class="text-sm opacity-60 mt-1">Your AI contacts — each tied to a model and persona</p>
          </div>
          <.link navigate={~p"/contacts/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-5" /> New Contact
          </.link>
        </div>

        <div :if={@personas == []} class="text-center py-16">
          <.icon name="hero-user-plus" class="size-16 mx-auto opacity-30" />
          <p class="mt-4 text-lg opacity-60">No contacts yet</p>
          <p class="text-sm opacity-40 mt-1">Create your first AI contact to start chatting</p>
          <.link navigate={~p"/contacts/new"} class="btn btn-primary mt-6">
            Create Your First Contact
          </.link>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <div :for={persona <- @personas} class="card bg-base-200 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-start gap-3">
                <div
                  class="w-12 h-12 rounded-full flex items-center justify-center text-white font-bold text-lg shrink-0"
                  style={"background-color: #{persona.color}"}
                >
                  {initials(persona.name)}
                </div>
                <div class="min-w-0 flex-1">
                  <h3 class="font-bold truncate">{persona.name}</h3>
                  <p class="text-sm opacity-60">
                    {persona.model}
                    <span :if={persona.group_model} class="opacity-50">
                       · group:  {persona.group_model}
                    </span>
                  </p>
                </div>
              </div>
              <p :if={persona.description} class="text-sm opacity-70 mt-2 line-clamp-2">
                {persona.description}
              </p>
              <p :if={persona.system_prompt} class="text-xs opacity-50 mt-1 line-clamp-1 font-mono">
                {String.slice(persona.system_prompt, 0..80)}
              </p>
              <div class="card-actions justify-end mt-3">
                <.link navigate={~p"/contacts/#{persona.id}/edit"} class="btn btn-ghost btn-sm">
                  Edit
                </.link>
                <button
                  phx-click="delete"
                  phx-value-id={persona.id}
                  data-confirm={"Delete #{persona.name}? All conversations with this contact will also be deleted."}
                  class="btn btn-ghost btn-sm text-error"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        </div>

        <div class="pt-4">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Back to Messages
          </.link>
        </div>
      </div>

      <%!-- New / Edit --%>
      <div :if={@live_action in [:new, :edit]} class="max-w-lg mx-auto">
        <.link navigate={~p"/contacts"} class="btn btn-ghost btn-sm mb-4">
          <.icon name="hero-arrow-left" class="size-4" /> Back to Contacts
        </.link>

        <h1 class="text-2xl font-bold mb-6">
          {if @live_action == :new, do: "New Contact", else: "Edit Contact"}
        </h1>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="e.g. Code Assistant" required />

          <.input
            field={@form[:model]}
            label="Model"
            type="select"
            options={@models}
            prompt="Choose a model..."
            required
          />

          <.input
            field={@form[:group_model]}
            label="Group Model (optional)"
            type="select"
            options={@models}
            prompt="Same as above"
          />
          <p class="text-xs opacity-50 -mt-2 ml-1">
            Uses a different model in group chats — useful for collaboration
          </p>

          <.input
            field={@form[:thinking]}
            label="Thinking"
            type="checkbox"
          />
          <p class="text-xs opacity-50 -mt-2 ml-1">
            Let the model reason before responding — better answers but slower, and small models may spiral
          </p>

          <.input
            field={@form[:system_prompt]}
            label="System Prompt (optional)"
            type="textarea"
            placeholder="You are a helpful assistant that specializes in..."
            rows={4}
          />

          <.input
            field={@form[:description]}
            label="Description (optional)"
            type="textarea"
            placeholder="What this contact is good at..."
            rows={2}
          />

          <div class="fieldset">
            <label class="label mb-2">Color</label>
            <div class="flex flex-wrap gap-2">
              <label
                :for={{name, hex} <- Persona.colors()}
                class={[
                  "w-10 h-10 rounded-full cursor-pointer border-3 transition-all",
                  if((@form[:color].value || "#6366f1") == hex,
                    do: "border-base-content scale-110",
                    else: "border-transparent hover:scale-105"
                  )
                ]}
                style={"background-color: #{hex}"}
                title={name}
              >
                <input
                  type="radio"
                  name={@form[:color].name}
                  value={hex}
                  class="hidden"
                  checked={(@form[:color].value || "#6366f1") == hex}
                />
              </label>
            </div>
          </div>

          <%!-- Preview --%>
          <div class="divider text-xs opacity-50">Preview</div>
          <div class="flex items-center gap-3 p-4 bg-base-200 rounded-lg">
            <div
              class="w-12 h-12 rounded-full flex items-center justify-center text-white font-bold text-lg shrink-0"
              style={"background-color: #{@form[:color].value || "#6366f1"}"}
            >
              {initials(@form[:name].value || "?")}
            </div>
            <div>
              <div class="font-bold">{@form[:name].value || "Contact Name"}</div>
              <div class="text-sm opacity-60">{@form[:model].value || "No model selected"}</div>
            </div>
          </div>

          <div class="flex gap-3 pt-4">
            <button type="submit" class="btn btn-primary">
              {if @live_action == :new, do: "Create Contact", else: "Save Changes"}
            </button>
            <.link navigate={~p"/contacts"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
