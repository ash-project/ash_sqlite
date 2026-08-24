# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.VerifyTenantBinder do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    if Ash.Resource.Info.multitenancy_strategy(dsl) == :context and
         is_nil(Verifier.get_option(dsl, [:sqlite], :tenant_binder)) do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:sqlite, :tenant_binder],
         message: """
         `strategy :context` needs a `tenant_binder`.

         SQLite has no schemas, so the tenant cannot be a query prefix: the SQL is \
         identical for every tenant and isolation comes from which file the \
         connection is attached to. Something has to choose that connection, and \
         only the application knows how.

             sqlite do
               tenant_binder MyApp.TenantBinder
             end

         See `AshSqlite.TenantBinder`.\
         """
       )}
    else
      :ok
    end
  end
end
