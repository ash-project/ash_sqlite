# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.UnconfiguredRepo do
  @moduledoc """
  A repo module with no configuration at all -- no `database:`, no name.

  That is a perfectly good template for tenants, which are reached through
  `Ecto.Repo.put_dynamic_repo/1`, and it is exactly what a `global? true` resource
  cannot use: there is no shared database for its one copy of the rows to live in.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite
end
