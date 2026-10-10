# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.VerifyTenantRepo do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    if Ash.Resource.Info.multitenancy_strategy(dsl) == :context and
         is_nil(Verifier.get_option(dsl, [:sqlite], :tenant_repo)) do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:sqlite, :tenant_repo],
         message: """
         `strategy :context` needs a `tenant_repo`.

         Each tenant has its own database file, so a tenanted statement has to be \
         given the repo instance for its tenant. Only the application knows how to \
         map a tenant to a repo instance.

             sqlite do
               repo MyApp.Repo
               tenant_repo &MyApp.Tenants.repo/2
             end

         See `AshSqlite.TenantRepo`.\
         """
       )}
    else
      :ok
    end
  end
end
