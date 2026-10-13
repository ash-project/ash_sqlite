# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.UnavailableError do
  @moduledoc """
  Raised when a tenant's database cannot be reached, rather than letting a statement run unbound.
  """
  defexception [:tenant, :reason]

  @impl true
  def message(%{tenant: tenant, reason: reason}) do
    """
    the database for tenant #{inspect(tenant)} is unavailable: #{inspect(reason)}

    No statement was run. Each tenant is its own SQLite file, so running without \
    one would have run against another tenant's data.
    """
  end
end
