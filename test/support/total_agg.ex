# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.TotalAgg do
  @moduledoc false

  use Ash.Resource.Aggregate.CustomAggregate
  use AshSqlite.CustomAggregate

  import Ecto.Query

  def dynamic(opts, binding) do
    field = Keyword.fetch!(opts, :field)

    dynamic(fragment("total(?)", field(as(^binding), ^field)))
  end
end
