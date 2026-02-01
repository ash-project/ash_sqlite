# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.Types.Status do
  @moduledoc false
  use Ash.Type.Enum, values: [:open, :closed]

  def storage_type, do: :string
end
