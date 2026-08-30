# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.UnstartedGlobalPost do
  @moduledoc """
  A `global? true` resource on a repo module that has no instance of its own.

  The shape that is easy to arrive at by accident: `AshSqlite.ManagedTenantRepo`
  serves its tenants entirely through `Ecto.Repo.put_dynamic_repo/1`, so it is never
  started under its own name and has no shared database to hold one copy of anything.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read])
  end

  multitenancy do
    strategy(:context)
    global?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
  end

  sqlite do
    table("unstarted_global_posts")
    repo(AshSqlite.ManagedTenantRepo)
    migrate?(false)
  end
end
