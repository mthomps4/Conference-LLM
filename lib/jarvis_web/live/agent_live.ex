defmodule JarvisWeb.AgentLive do
  use JarvisWeb, :live_view

  alias Jarvis.Agents
  alias Jarvis.Chat.Persona

  @impl true
  def mount(_params, _session, socket) do
    llm = Jarvis.LLM.provider()

    models =
      case llm.list_models() do
        {:ok, m} -> m
        _ -> [llm.default_model()]
      end

    {:ok, assign(socket, models: models, agents: Agents.list_agents())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, persona: nil, form: nil, page_title: "Agents")
  end

  defp apply_action(socket, :new, _params) do
    persona = %Persona{color: "#6366f1"}
    changeset = Agents.change_agent(persona)

    assign(socket,
      persona: persona,
      form: to_form(changeset),
      page_title: "New Agent"
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    persona = Agents.get_agent!(id)
    changeset = Agents.change_agent(persona)

    assign(socket,
      persona: persona,
      form: to_form(changeset),
      page_title: "Edit #{persona.name}"
    )
  end

  @impl true
  def handle_event("validate", %{"persona" => params}, socket) do
    changeset =
      socket.assigns.persona
      |> Agents.change_agent(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"persona" => params}, socket) do
    save_agent(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    persona = Agents.get_agent!(id)
    {:ok, _} = Agents.delete_agent(persona)
    agents = Enum.reject(socket.assigns.agents, &(&1.id == persona.id))

    {:noreply,
     socket
     |> assign(agents: agents)
     |> put_flash(:info, "#{persona.name} deleted")}
  end

  defp save_agent(socket, :new, params) do
    case Agents.create_agent(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent created")
         |> push_navigate(to: ~p"/agents")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_agent(socket, :edit, params) do
    case Agents.update_agent(socket.assigns.persona, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent updated")
         |> push_navigate(to: ~p"/agents")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp initials(name) when is_binary(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Index --%>
      <div :if={@live_action == :index} class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">Agents</h1>
            <p class="text-sm opacity-60 mt-1">
              AI agents — each with a model, persona, and system prompt
            </p>
          </div>
          <.link navigate={~p"/agents/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-5" /> New Agent
          </.link>
        </div>

        <div :if={@agents == []} class="text-center py-16">
          <.icon name="hero-cpu-chip" class="size-16 mx-auto opacity-30" />
          <p class="mt-4 text-lg opacity-60">No agents yet</p>
          <.link navigate={~p"/agents/new"} class="btn btn-primary mt-6">
            Create Your First Agent
          </.link>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <div :for={agent <- @agents} class="card bg-base-200 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-start gap-3">
                <div
                  class="w-12 h-12 rounded-full flex items-center justify-center text-white font-bold text-lg shrink-0"
                  style={"background-color: #{agent.color}"}
                >
                  {initials(agent.name)}
                </div>
                <div class="min-w-0 flex-1">
                  <h3 class="font-bold truncate">{agent.name}</h3>
                  <p class="text-sm opacity-60">
                    {agent.model}
                    <span :if={agent.group_model} class="opacity-50">
                      · group: {agent.group_model}
                    </span>
                  </p>
                </div>
              </div>
              <p :if={agent.description} class="text-sm opacity-70 mt-2 line-clamp-2">
                {agent.description}
              </p>
              <p :if={agent.system_prompt} class="text-xs opacity-50 mt-1 line-clamp-1 font-mono">
                {String.slice(agent.system_prompt, 0..80)}
              </p>
              <div class="card-actions justify-end mt-3">
                <.link navigate={~p"/agents/#{agent.id}/edit"} class="btn btn-ghost btn-sm">
                  Edit
                </.link>
                <button
                  phx-click="delete"
                  phx-value-id={agent.id}
                  data-confirm={"Delete #{agent.name}?"}
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
            <.icon name="hero-arrow-left" class="size-4" /> Back to Workspace
          </.link>
        </div>
      </div>

      <%!-- New / Edit --%>
      <div :if={@live_action in [:new, :edit]} class="max-w-lg mx-auto">
        <.link navigate={~p"/agents"} class="btn btn-ghost btn-sm mb-4">
          <.icon name="hero-arrow-left" class="size-4" /> Back to Agents
        </.link>

        <h1 class="text-2xl font-bold mb-6">
          {if @live_action == :new, do: "New Agent", else: "Edit Agent"}
        </h1>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="e.g. Architect" required />

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
            Uses a different model in group chats
          </p>

          <.input field={@form[:thinking]} label="Extended Thinking" type="checkbox" />
          <p class="text-xs opacity-50 -mt-2 ml-1">
            Let the model reason before responding
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
            placeholder="What this agent is good at..."
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
              <div class="font-bold">{@form[:name].value || "Agent Name"}</div>
              <div class="text-sm opacity-60">{@form[:model].value || "No model selected"}</div>
            </div>
          </div>

          <div class="flex gap-3 pt-4">
            <button type="submit" class="btn btn-primary">
              {if @live_action == :new, do: "Create Agent", else: "Save Changes"}
            </button>
            <.link navigate={~p"/agents"} class="btn btn-ghost">Cancel</.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
