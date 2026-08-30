# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantRepo do
  @moduledoc """
  A repo used as a template, started per tenant as an anonymous instance rather than under its own name.
  """
  use AshSqlite.Repo, otp_app: :ash_sqlite
end
