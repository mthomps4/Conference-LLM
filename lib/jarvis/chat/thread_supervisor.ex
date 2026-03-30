defmodule Jarvis.Chat.ThreadSupervisor do
  @moduledoc """
  DynamicSupervisor for per-thread GenServer processes.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_thread(thread_id) do
    DynamicSupervisor.start_child(__MODULE__, {Jarvis.Chat.ThreadServer, thread_id})
  end

  def stop_thread(thread_id) do
    case Registry.lookup(Jarvis.Chat.ThreadRegistry, thread_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end
end
