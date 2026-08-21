# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantRepo do
  @moduledoc """
  A repo used as a template rather than started under its own name.

  Database-per-tenant means one connection per database file, so the tests start an
  anonymous instance of this per tenant and bind it with
  `c:Ecto.Repo.put_dynamic_repo/1`. Nothing ever starts it as `AshSqlite.TenantRepo`,
  which is also why `AshSqlite.DataLayer.in_transaction?/1` has to cope with a repo
  that has no named process.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite
end
