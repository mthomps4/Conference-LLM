defmodule Jarvis.Models do
  @moduledoc """
  Model configuration registry. Maps model names to known context window sizes
  and other properties. Used by messages_for_ollama to set token budgets.

  Add entries here as you install new models. Unknown models get conservative defaults.
  """

  # Context sizes in tokens (approximate). Conservative estimates.
  @model_configs %{
    "qwen3:0.6b" => %{context_tokens: 4_000},
    "qwen3:4b" => %{context_tokens: 8_000},
    "qwen3:8b" => %{context_tokens: 8_000},
    "qwen2.5-coder:7b" => %{context_tokens: 8_000},
    "qwen3:14b" => %{context_tokens: 32_000},
    "qwen3:30b-a3b" => %{context_tokens: 32_000},
    "llama3.1:8b" => %{context_tokens: 128_000},
    "llama3.1:70b" => %{context_tokens: 128_000},
    "deepseek-coder-v2:16b" => %{context_tokens: 128_000}
  }

  @default_context_tokens 6_000

  @doc """
  Returns the context window size (in tokens) for a given model.
  Uses a conservative default for unknown models.
  """
  def context_tokens(model) do
    case Map.get(@model_configs, model) do
      %{context_tokens: tokens} -> tokens
      nil -> @default_context_tokens
    end
  end

  @doc """
  Returns a token budget for message assembly.
  Reserves ~25% of context for the model's response.
  """
  def message_budget(model) do
    trunc(context_tokens(model) * 0.75)
  end

  @doc """
  Returns all known model configurations.
  """
  def all, do: @model_configs

  @doc """
  Returns the default context tokens for unknown models.
  """
  def default_context_tokens, do: @default_context_tokens
end
