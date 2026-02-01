# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Functions.Like do
  @moduledoc """
  Maps to the builtin sqlite function `like`.
  """

  use Ash.Query.Function, name: :like

  def args, do: [[:string, :string]]
end
