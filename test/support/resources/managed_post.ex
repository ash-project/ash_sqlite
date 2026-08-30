# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.ManagedPost do
  @moduledoc """
  A `strategy :context` resource with no `tenant_binder`, so it gets the default.
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
    table("managed_posts")
    repo(AshSqlite.ManagedTenantRepo)
    write_transactions?(true)
    migrate?(false)
  end
end
