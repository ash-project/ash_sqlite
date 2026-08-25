# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TransactionTestRepo do
  @moduledoc """
  A second repo on the same database file as `AshSqlite.TestRepo`, with write
  transactions on.

  The pair is what makes the feature testable: `write_transactions?` is a repo
  callback, so showing a failure roll back and the same failure not roll back takes
  two repos rather than two resources.
  """
  use AshSqlite.Repo,
    otp_app: :ash_sqlite

  def write_transactions?, do: true
end
