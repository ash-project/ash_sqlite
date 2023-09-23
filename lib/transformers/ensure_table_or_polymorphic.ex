defmodule AshSqlite.Transformers.EnsureTableOrPolymorphic do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    if Transformer.get_option(dsl, [:sqlite], :polymorphic?) ||
         Transformer.get_option(dsl, [:sqlite], :table) do
      {:ok, dsl}
    else
      resource = Transformer.get_persisted(dsl, :module)

      raise Spark.Error.DslError,
        module: resource,
        message: """
        Must configure a table for #{inspect(resource)}.

        For example:

        ```elixir
        sqlite do
          table "the_table"
          repo YourApp.Repo
        end
        ```
        """,
        path: [:sqlite, :table]
    end
  end
end
