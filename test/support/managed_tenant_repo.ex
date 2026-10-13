# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.ManagedTenantRepo do
  @moduledoc """
  The repo whose tenants `AshSqlite.MultiTenancy` manages, kept apart from
  `AshSqlite.TenantTestRepo` so the two cannot interfere.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite

  def min_sqlite_version do
    %Version{major: 3, minor: 38, patch: 0}
  end

  # Transactions are a repo decision rather than a resource one.
  def write_transactions?, do: true
end
