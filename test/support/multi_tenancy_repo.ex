# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.MultiTenancyRepo do
  @moduledoc """
  A tenant repo whose tenants are managed by `AshSqlite.MultiTenancy`.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite

  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}

  def write_transactions?, do: true

  def tenant_repo(tenant, context),
    do: AshSqlite.MultiTenancy.tenant_repo(__MODULE__, tenant, context)
end
