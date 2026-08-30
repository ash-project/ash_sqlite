# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Binder do
  @moduledoc """
  Implements `AshSqlite.TenantBinder` in terms of `AshSqlite.MultiTenancy`. The default for `strategy :context`.
  """

  @behaviour AshSqlite.TenantBinder

  @impl true
  def bind(tenant, opts, fun) do
    resource = Keyword.fetch!(opts, :resource)
    repo = AshSqlite.DataLayer.Info.repo(resource, :mutate)
    AshSqlite.MultiTenancy.with_tenant(repo, tenant, fun)
  end
end
