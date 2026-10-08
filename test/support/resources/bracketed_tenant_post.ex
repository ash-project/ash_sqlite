# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.BracketedTenantPost do
  @moduledoc """
  `AshSqlite.Test.TenantedPost`'s table, reached through a tenant repo module that
  implements `with_repo/4`.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read])
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
    repo(AshSqlite.TenantTestRepo)
    tenant_repo(AshSqlite.Test.BracketingTenantRepo)
    migrate?(false)
  end
end
