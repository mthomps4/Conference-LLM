defmodule Jarvis.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JarvisWeb.Telemetry,
      Jarvis.Repo,
      {DNSCluster, query: Application.get_env(:jarvis, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Jarvis.PubSub},
      {Registry, keys: :unique, name: Jarvis.Chat.ThreadRegistry},
      {Jarvis.Chat.ThreadSupervisor, []},
      Jarvis.Ollama,
      JarvisWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Jarvis.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    JarvisWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
