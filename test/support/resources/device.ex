# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.Device do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("devices")
    repo(AshSqlite.TestRepo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:id, :name, :entity])
    end

    update :update_entity do
      accept([:entity])
    end
  end

  attributes do
    attribute :id, :string do
      writable?(true)
      generated?(false)
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :entity, :map do
      allow_nil?(false)
      public?(true)
    end

    timestamps()
  end

  identities do
    identity(:unique_id, [:id])
  end
end
