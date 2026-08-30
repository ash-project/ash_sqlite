# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.GlobalPost do
  @moduledoc """
  A `strategy :context` resource that Ash also allows without a tenant.

  Shares `AshSqlite.TenantRepo` with `AshSqlite.Test.TenantedPost`, which is what
  makes it worth having: Ecto binds per repo *module*, so this resource sees
  whatever tenant the calling process last bound.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])
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
    table("global_posts")
    repo(AshSqlite.TenantRepo)
    tenant_binder(AshSqlite.Test.TenantBinder)
    migrate?(false)
  end
end
