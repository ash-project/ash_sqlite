# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.VerifyTenantRepo do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  # `put_dynamic_repo/1` binds per repo *module*, and the default tenant repo binds
  # the mutate one -- so a split read repo would serve reads from its own configured
  # database, unbound, with nothing raising. Only checked for the default: a tenant
  # repo of its own sees `type` and can bind a replica deliberately.
  @impl true
  def verify(dsl) do
    with true <- Ash.Resource.Info.multitenancy_strategy(dsl) == :context,
         nil <- Verifier.get_option(dsl, [:sqlite], :tenant_repo),
         fun when is_function(fun, 2) <- Verifier.get_option(dsl, [:sqlite], :repo) do
      resource = Verifier.get_persisted(dsl, :module)
      verify_same_repo(resource, fun.(resource, :read), fun.(resource, :mutate))
    else
      _ -> :ok
    end
  end

  defp verify_same_repo(_resource, repo, repo), do: :ok

  defp verify_same_repo(resource, read, mutate) do
    {:error,
     DslError.exception(
       module: resource,
       path: [:sqlite, :repo],
       message: """
       #{inspect(resource)} has `strategy :context` and a `repo` function returning \
       #{inspect(read)} for :read and #{inspect(mutate)} for :mutate.

       `AshSqlite.MultiTenancy.TenantRepo` selects a connection with \
       `Ecto.Repo.put_dynamic_repo/1`, which binds one repo *module*. It binds the \
       mutate repo, so reads would be issued on #{inspect(read)} unbound, against \
       whatever database that module was configured with rather than this tenant's.

       Either return one module for both, or name a `tenant_repo` of your own. A \
       tenant repo is told whether each statement is a `:read` or a `:mutate`, so \
       binding a read replica separately is something only it can do correctly.
       """
     )}
  end
end
