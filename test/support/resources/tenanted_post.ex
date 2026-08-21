# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.TenantedPost do
  @moduledoc """
  A `strategy :context` resource whose tenant is a database file.

  `migrate? false` because its table is created directly in each tenant's file by
  the test setup — there is no one database for the generator to migrate, which is
  the whole shape of database-per-tenant.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
  end

  sqlite do
    table("tenanted_posts")
    repo(AshSqlite.TenantRepo)
    tenant_binder(AshSqlite.Test.TenantBinder)
    write_transactions?(true)
    migrate?(false)
  end
end
