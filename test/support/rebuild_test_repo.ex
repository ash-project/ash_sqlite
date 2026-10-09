# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.RebuildTestRepo do
  @moduledoc """
  A repo with an ordinary pool (no sandbox) whose database file is chosen per test
  through the application environment, see `AshSqlite.RebuildHelper`.
  """
  use AshSqlite.Repo,
    otp_app: :ash_sqlite

  def min_sqlite_version do
    %Version{major: 3, minor: 38, patch: 0}
  end
end

defmodule AshSqlite.RebuildLibSqlRepo do
  @moduledoc "Like `AshSqlite.RebuildTestRepo`, on the optional ecto_libsql adapter."
  use AshSqlite.Repo,
    otp_app: :ash_sqlite,
    adapter: Ecto.Adapters.LibSql

  def min_sqlite_version do
    %Version{major: 3, minor: 38, patch: 0}
  end
end
