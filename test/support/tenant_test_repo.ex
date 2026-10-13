# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantTestRepo do
  @moduledoc """
  A tenant repo, started per tenant as an anonymous instance rather than under its own name.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite

  def min_sqlite_version do
    %Version{major: 3, minor: 38, patch: 0}
  end

  # Transactions are a repo decision rather than a resource one, so the tenanted
  # tests get them by asking here.
  def write_transactions?, do: true

  def tenant_repo(tenant, context), do: AshSqlite.Test.TenantRepos.repo(tenant, context)
end
