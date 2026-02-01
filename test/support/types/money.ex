# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.Money do
  @moduledoc false
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    attribute :amount, :integer do
      public?(true)
      allow_nil?(false)
      constraints(min: 0)
    end

    attribute :currency, :atom do
      public?(true)
      constraints(one_of: [:eur, :usd])
    end
  end
end
