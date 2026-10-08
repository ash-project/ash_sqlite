# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantRepo.Function do
  @moduledoc false
  @behaviour AshSqlite.TenantRepo

  @impl true
  def repo(tenant, context, fun: fun), do: fun.(tenant, context)
end
