defmodule AshSqlite.Transformers.VerifyRepo do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after_compile?, do: true

  def transform(dsl) do
    repo = Transformer.get_option(dsl, [:sqlite], :repo)

    cond do
      match?({:error, _}, Code.ensure_compiled(repo)) ->
        {:error, "Could not find repo module #{repo}"}

      repo.__adapter__() != Ecto.Adapters.SQLite3 ->
        {:error, "Expected a repo using the sqlite adapter `Ecto.Adapters.SQLite3`"}

      true ->
        {:ok, dsl}
    end
  end
end
