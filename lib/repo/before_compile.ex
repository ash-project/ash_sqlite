# SPDX-FileCopyrightText: 2026 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Repo.BeforeCompile do
  @moduledoc false

  defmacro __before_compile__(_env) do
    quote do
      if !Module.defines?(__MODULE__, {:min_sqlite_version, 0}, :def) do
        IO.warn("""
        Please define `min_sqlite_version/0` in repo module: #{inspect(__MODULE__)}

        For example:

            def min_sqlite_version do
              %Version{major: 3, minor: 53, patch: 4}
            end

        The lowest compatible version is being assumed.
        """)

        def min_sqlite_version do
          %Version{major: 3, minor: 38, patch: 0}
        end
      end
    end
  end
end
