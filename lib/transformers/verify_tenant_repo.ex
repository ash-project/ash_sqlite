# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Transformers.VerifyTenantRepo do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # `after_compile?`, as `VerifyRepo` is: Spark stores a `repo` function as a
  # generated function *on the resource*, so there is nothing to call until the
  # module exists.
  def after_compile?, do: true

  # `put_dynamic_repo/1` binds per repo *module*, so a binder can only bind one of
  # them. `AshSqlite.MultiTenancy.Binder` binds the mutate repo; a resource whose
  # read repo is a different module would issue its reads on a module nothing bound,
  # against that module's own configured database -- which for a database-per-tenant
  # layout is every tenant's rows at once, with nothing raising.
  #
  # Only checked for the default binder. A binder of its own sees `usage` and can
  # bind a read replica separately, which is the case this would otherwise forbid.
  def transform(dsl) do
    with true <- Ash.Resource.Info.multitenancy_strategy(dsl) == :context,
         nil <- Transformer.get_option(dsl, [:sqlite], :tenant_binder),
         fun when is_function(fun, 2) <- Transformer.get_option(dsl, [:sqlite], :repo) do
      resource = Transformer.get_persisted(dsl, :module)
      verify(dsl, resource, fun.(resource, :read), fun.(resource, :mutate))
    else
      _ -> {:ok, dsl}
    end
  end

  defp verify(dsl, _resource, repo, repo), do: {:ok, dsl}

  defp verify(_dsl, resource, read, mutate) do
    {:error,
     """
     #{inspect(resource)} has `strategy :context` and a `repo` function returning \
     #{inspect(read)} for :read and #{inspect(mutate)} for :mutate.

     A tenant binder selects a connection with `Ecto.Repo.put_dynamic_repo/1`, which \
     binds one repo *module*. The default binder binds the mutate repo, so reads \
     would be issued on #{inspect(read)} unbound -- against whatever database that \
     module was configured with, rather than this tenant's.

     Either return one module for both, or name a `tenant_binder` of your own. A \
     binder is told whether each statement is a `:read` or a `:write`, so binding a \
     read replica separately is something only it can do correctly.
     """}
  end
end
