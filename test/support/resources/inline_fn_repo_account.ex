# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.InlineFnRepoAccount do
  @moduledoc """
  A resource whose `repo` is an inline `fn`, on the `accounts` table.

  Spark hoists the `fn` into a function on this module, so it cannot be called while
  this module is compiling, which is when `:transact` is first asked about. Its
  existence is the regression test: the suite would not compile if that case raised.
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

    repo(fn
      _resource, :mutate -> AshSqlite.TestRepo
      _resource, :read -> AshSqlite.TestRepo
    end)
  end
end
