# SPDX-FileCopyrightText: 2020 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Functions.Like do
  @moduledoc """
  Maps to the builtin sqlite function `like`.
  """

  use Ash.Query.Function, name: :like

  def args, do: [[:string, :string]]
end
