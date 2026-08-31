# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.NamedFnRepoAccount do
  @moduledoc """
  A resource whose `repo` captures a named function, on the `accounts` table.

  The only supported form for a function repo: unlike an inline `fn`, a capture of a
  named function in another module resolves while the resource compiles, so its
  actions report the transaction they will really get.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:is_active, :boolean, public?: true)
  end

  sqlite do
    table("accounts")
    # `AshSqlite.Test.Account` owns the snapshot for this table.
    migrate?(false)

    repo(&AshSqlite.Test.RepoRouting.repo/2)
  end
end
