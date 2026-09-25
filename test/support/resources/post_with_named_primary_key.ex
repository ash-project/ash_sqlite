# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.PostWithNamedPrimaryKey do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("posts")
    repo(AshSqlite.TestRepo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute :post_key, :uuid do
      source(:id)
      primary_key?(true)
      allow_nil?(false)
    end

    attribute(:title, :string, public?: true)
  end
end
