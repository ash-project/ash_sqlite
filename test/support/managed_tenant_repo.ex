# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.ManagedTenantRepo do
  @moduledoc """
  The repo whose tenants `AshSqlite.MultiTenancy` manages, kept apart from
  `AshSqlite.TenantRepo` so the two binders cannot interfere.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite

  # Transactions are a repo decision rather than a resource one.
  def write_transactions?, do: true
end
