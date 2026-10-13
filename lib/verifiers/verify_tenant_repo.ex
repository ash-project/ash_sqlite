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
    context? = Ash.Resource.Info.multitenancy_strategy(dsl) == :context

    # A function `repo` can name a different module for reads and writes.
    [:read, :mutate]
    |> Enum.map(&AshSqlite.DataLayer.Info.repo(dsl, &1))
    |> Enum.uniq()
    |> Enum.filter(&match?({:module, _}, Code.ensure_compiled(&1)))
    |> Enum.find_value(:ok, fn repo ->
      case {context?, AshSqlite.DataLayer.tenant_repo?(repo)} do
        {true, false} -> {:error, not_a_tenant_repo(dsl, repo)}
        {false, true} -> {:error, not_context(dsl, repo)}
        _ -> nil
      end
    end)
  end

  defp not_a_tenant_repo(dsl, repo) do
    DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:sqlite, :repo],
      message: """
      `strategy :context` needs a tenant repo, but #{inspect(repo)} does not \
      implement `c:AshSqlite.Repo.tenant_repo/2`.

      Each tenant has its own database file, so a tenanted statement has to be \
      given the repo instance for its tenant. Only the application knows how to map \
      a tenant to a repo instance:

          defmodule MyApp.TenantRepo do
            use AshSqlite.Repo, otp_app: :my_app

            def tenant_repo(tenant, _context), do: MyApp.Tenants.repo_for(tenant)
          end
      """
    )
  end

  defp not_context(dsl, repo) do
    DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:sqlite, :repo],
      message: """
      #{inspect(repo)} is a tenant repo, so every resource on it must use \
      `strategy :context`.

      Ecto binds a repo instance per repo module, not per resource. Inside a \
      tenant's transaction this resource would run on that tenant's database. Put \
      it on a repo module of its own:

          sqlite do
            repo MyApp.SharedRepo
          end
      """
    )
  end
end
