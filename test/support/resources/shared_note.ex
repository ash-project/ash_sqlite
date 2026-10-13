# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.SharedNote do
  @moduledoc """
  A resource with no multitenancy on the same repo module as `AshSqlite.Test.TenantedPost`.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true)
  end

  sqlite do
    table("shared_notes")
    repo(AshSqlite.TenantTestRepo)
    migrate?(false)
  end
end
