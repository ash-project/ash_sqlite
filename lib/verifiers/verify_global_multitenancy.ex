# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.VerifyGlobalMultitenancy do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    if Ash.Resource.Info.multitenancy_strategy(dsl) == :context and
         Ash.Resource.Info.multitenancy_global?(dsl) do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:multitenancy, :global?],
         message: """
         `global? true` is not supported with `strategy :context`.

         `global?` allows a resource to be used with or without a tenant. Each \
         tenant has its own database file here, so a statement that carries no \
         tenant names no database, and there is no shared connection to fall back \
         to. What such a resource should do has not been decided yet, so it is \
         refused rather than guessed at.

         Put shared tables on a resource with no multitenancy, pointing at a repo \
         module of their own:

             sqlite do
               repo MyApp.SharedRepo
             end
         """
       )}
    else
      :ok
    end
  end
end
