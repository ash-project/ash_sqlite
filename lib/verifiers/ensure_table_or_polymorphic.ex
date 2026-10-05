# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.EnsureTableOrPolymorphic do
  @moduledoc false
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  def verify(dsl) do
    if Verifier.get_option(dsl, [:sqlite], :polymorphic?) ||
         Verifier.get_option(dsl, [:sqlite], :table) do
      :ok
    else
      resource = Verifier.get_persisted(dsl, :module)

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
