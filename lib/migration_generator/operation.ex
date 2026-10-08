# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MigrationGenerator.Operation do
  @moduledoc false

  defmodule Helper do
    @moduledoc false
    def join(list),
      do:
        list
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")
        |> String.replace(", )", ")")

    def maybe_add_default("nil"), do: nil
    def maybe_add_default(value), do: "default: #{value}"

    def maybe_add_primary_key(true), do: "primary_key: true"
    def maybe_add_primary_key(_), do: nil

    def maybe_add_null(false), do: "null: false"
    def maybe_add_null(_), do: nil

    def in_quotes(nil), do: nil
    def in_quotes(value), do: "\"#{value}\""

    def as_atom(value) when is_atom(value), do: Macro.inspect_atom(:remote_call, value)
    # sobelow_skip ["DOS.StringToAtom"]
    def as_atom(value), do: Macro.inspect_atom(:remote_call, String.to_atom(value))

    def option(key, value) when key in [:nulls_distinct, "nulls_distinct"] do
      if !value do
        "#{as_atom(key)}: #{inspect(value)}"
      end
    end

    def option(key, value) do
      if value do
        "#{as_atom(key)}: #{inspect(value)}"
      end
    end

    def on_delete(%{on_delete: on_delete}) when on_delete in [:delete, :nilify] do
      "on_delete: :#{on_delete}_all"
    end

    def on_delete(%{on_delete: on_delete}) when is_atom(on_delete) and not is_nil(on_delete) do
      "on_delete: :#{on_delete}"
    end

    def on_delete(_), do: nil

    def on_update(%{on_update: on_update}) when on_update in [:update, :nilify] do
      "on_update: :#{on_update}_all"
    end

    def on_update(%{on_update: on_update}) when is_atom(on_update) and not is_nil(on_update) do
      "on_update: :#{on_update}"
    end

    def on_update(_), do: nil

    def reference_type(
          %{type: :integer},
          %{destination_attribute_generated: true, destination_attribute_default: "nil"}
        ) do
      :bigint
    end

    def reference_type(%{type: type}, _) do
      type
    end
  end

  defmodule CreateTable do
    @moduledoc false
    defstruct [:table, :multitenancy, :old_multitenancy, options: []]
  end

  defmodule AddAttribute do
    @moduledoc false
    defstruct [:attribute, :table, :multitenancy, :old_multitenancy]

    import Helper

    def up(%{
          multitenancy: %{strategy: :attribute, attribute: source_attribute},
          attribute:
            %{
              references:
                %{
                  table: table,
                  destination_attribute: reference_attribute,
                  multitenancy: %{strategy: :attribute, attribute: destination_attribute}
                } = reference
            } = attribute
        }) do
      # Non-primary-key destinations always include the tenant column.
      # Primary-key destinations only do so when match_tenant?: true (opt-in).
      with_match =
        if destination_attribute != reference_attribute &&
             (!Map.get(reference, :primary_key?, false) ||
                Map.get(reference, :match_tenant?, false)) do
          "with: [#{as_atom(source_attribute)}: :#{as_atom(destination_attribute)}], match: :full"
        end

      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      [
        "add #{inspect(attribute.source)}",
        "references(:#{as_atom(table)}",
        [
          "column: #{inspect(reference_attribute)}",
          with_match,
          "name: #{inspect(reference.name)}",
          "type: #{inspect(reference_type(attribute, reference))}",
          on_delete(reference),
          on_update(reference),
          size
        ],
        ")",
        maybe_add_default(attribute.default),
        maybe_add_primary_key(attribute.primary_key?),
        maybe_add_null(attribute.allow_nil?)
      ]
      |> join()
    end

    def up(%{
          attribute:
            %{
              references:
                %{
                  table: table,
                  destination_attribute: destination_attribute
                } = reference
            } = attribute
        }) do
      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      [
        "add #{inspect(attribute.source)}",
        "references(:#{as_atom(table)}",
        [
          "column: #{inspect(destination_attribute)}",
          "name: #{inspect(reference.name)}",
          "type: #{inspect(reference_type(attribute, reference))}",
          size,
          on_delete(reference),
          on_update(reference)
        ],
        ")",
        maybe_add_default(attribute.default),
        maybe_add_primary_key(attribute.primary_key?),
        maybe_add_null(attribute.allow_nil?)
      ]
      |> join()
    end

    def up(%{attribute: %{type: :bigint, default: "nil", generated?: true} = attribute}) do
      [
        "add #{inspect(attribute.source)}",
        ":bigserial",
        maybe_add_null(attribute.allow_nil?),
        maybe_add_primary_key(attribute.primary_key?)
      ]
      |> join()
    end

    def up(%{attribute: %{type: :integer, default: "nil", generated?: true} = attribute}) do
      [
        "add #{inspect(attribute.source)}",
        ":serial",
        maybe_add_null(attribute.allow_nil?),
        maybe_add_primary_key(attribute.primary_key?)
      ]
      |> join()
    end

    def up(%{attribute: attribute}) do
      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      [
        "add #{inspect(attribute.source)}",
        "#{inspect(attribute.type)}",
        maybe_add_null(attribute.allow_nil?),
        maybe_add_default(attribute.default),
        size,
        maybe_add_primary_key(attribute.primary_key?)
      ]
      |> join()
    end

    def down(
          %{
            attribute: attribute,
            table: table,
            multitenancy: multitenancy
          } = op
        ) do
      AshSqlite.MigrationGenerator.Operation.RemoveAttribute.up(%{
        op
        | attribute: attribute,
          table: table,
          multitenancy: multitenancy
      })
    end
  end

  defmodule AlterDeferrability do
    @moduledoc false
    # TODO: support once 3.54.0 lands. https://sqlite.org/src/info/4b0882cdb5b7947b
    # Emulate this by dropping the constraint and create a new one.

    defstruct [:table, :references, :direction, no_phase: true]

    def up(%{direction: :up, table: table, references: %{name: name}}) do
      ~s[raise "SQLite does not support altering foreign key constraints. " <>
          "You will need to manually recreate the `#{table}` with the `#{name}` constraint. " <>
          "See https://www.techonthenet.com/sqlite/foreign_keys/drop.php for guidance."]
    end

    def up(_), do: ""

    def down(%{direction: :down} = data), do: up(%{data | direction: :up})
    def down(_), do: ""
  end

  defmodule AlterAttribute do
    @moduledoc false
    defstruct [
      :old_attribute,
      :new_attribute,
      :table,
      :multitenancy,
      :old_multitenancy
    ]

    import Helper

    defp alter_opts(attribute, old_attribute) do
      primary_key =
        cond do
          attribute.primary_key? and !old_attribute.primary_key? ->
            ", primary_key: true"

          old_attribute.primary_key? and !attribute.primary_key? ->
            ", primary_key: false"

          true ->
            nil
        end

      default =
        if attribute.default != old_attribute.default do
          if is_nil(attribute.default) do
            ", default: nil"
          else
            ", default: #{attribute.default}"
          end
        end

      null =
        if attribute.allow_nil? != old_attribute.allow_nil? do
          ", null: #{attribute.allow_nil?}"
        end

      "#{null}#{default}#{primary_key}"
    end

    def up(%{
          multitenancy: multitenancy,
          old_attribute: old_attribute,
          new_attribute: attribute
        }) do
      type_or_reference =
        if AshSqlite.MigrationGenerator.has_reference?(multitenancy, attribute) and
             Map.get(old_attribute, :references) != Map.get(attribute, :references) do
          reference(multitenancy, attribute)
        else
          inspect(attribute.type)
        end

      "modify #{inspect(attribute.source)}, #{type_or_reference}#{alter_opts(attribute, old_attribute)}"
    end

    defp reference(
           %{strategy: :attribute, attribute: source_attribute},
           %{
             references:
               %{
                 multitenancy: %{strategy: :attribute, attribute: destination_attribute},
                 table: table,
                 destination_attribute: reference_attribute
               } = reference
           } = attribute
         ) do
      # Non-primary-key destinations always include the tenant column.
      # Primary-key destinations only do so when match_tenant?: true (opt-in).
      with_match =
        if destination_attribute != reference_attribute &&
             (!Map.get(reference, :primary_key?, false) ||
                Map.get(reference, :match_tenant?, false)) do
          "with: [#{as_atom(source_attribute)}: :#{as_atom(destination_attribute)}], match: :full"
        end

      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      join([
        "references(:#{as_atom(table)}, column: #{inspect(reference_attribute)}",
        with_match,
        "name: #{inspect(reference.name)}",
        "type: #{inspect(reference_type(attribute, reference))}",
        size,
        on_delete(reference),
        on_update(reference),
        ")"
      ])
    end

    defp reference(
           _,
           %{
             references:
               %{
                 table: table,
                 destination_attribute: destination_attribute
               } = reference
           } = attribute
         ) do
      size =
        if attribute[:size] do
          "size: #{attribute[:size]}"
        end

      join([
        "references(:#{as_atom(table)}, column: #{inspect(destination_attribute)}",
        "name: #{inspect(reference.name)}",
        "type: #{inspect(reference_type(attribute, reference))}",
        size,
        on_delete(reference),
        on_update(reference),
        ")"
      ])
    end

    def down(op) do
      up(%{
        op
        | old_attribute: op.new_attribute,
          new_attribute: op.old_attribute,
          old_multitenancy: op.multitenancy,
          multitenancy: op.old_multitenancy
      })
    end
  end

  defmodule DropForeignKey do
    @moduledoc false
    # TODO: support once 3.54.0 lands. https://sqlite.org/src/info/4b0882cdb5b7947b

    # We only run this migration in one direction, based on the input
    # This is because the creation of a foreign key is handled by `references/3`
    # We only need to drop it before altering an attribute with `references/3`
    defstruct [:attribute, :table, :multitenancy, :direction, no_phase: true]

    def up(%{table: table, attribute: %{references: reference}, direction: :up}) do
      ~s[raise "SQLite does not support dropping foreign key constraints. " <>
          "You will need to manually recreate the `#{table}` table without the `#{reference.name}` constraint. " <>
          "See https://www.techonthenet.com/sqlite/foreign_keys/drop.php for guidance."]
    end

    def up(_) do
      ""
    end

    def down(%{
          table: table,
          attribute: %{references: reference},
          direction: :down
        }) do
      ~s[raise "SQLite does not support dropping foreign key constraints. " <>
          "You will need to manually recreate the `#{table}` table without the `#{reference.name}` constraint. " <>
          "See https://www.techonthenet.com/sqlite/foreign_keys/drop.php for guidance."]
    end

    def down(_) do
      ""
    end
  end

  defmodule RenameAttribute do
    @moduledoc false
    defstruct [
      :old_attribute,
      :new_attribute,
      :table,
      :multitenancy,
      :old_multitenancy,
      no_phase: true
    ]

    import Helper

    def up(%{
          old_attribute: old_attribute,
          new_attribute: new_attribute,
          table: table
        }) do
      table_statement = join([":#{as_atom(table)}"])

      "rename table(#{table_statement}), #{inspect(old_attribute.source)}, to: #{inspect(new_attribute.source)}"
    end

    def down(
          %{
            old_attribute: old_attribute,
            new_attribute: new_attribute
          } = data
        ) do
      up(%{data | new_attribute: old_attribute, old_attribute: new_attribute})
    end
  end

  defmodule RemoveAttribute do
    @moduledoc false
    defstruct [:attribute, :table, :multitenancy, :old_multitenancy, commented?: true]

    def up(%{attribute: attribute, commented?: true}) do
      """
      # Attribute removal has been commented out to avoid data loss. See the migration generator documentation for more
      # If you uncomment this, be sure to also uncomment the corresponding attribute *addition* in the `down` migration
      # remove #{inspect(attribute.source)}
      """
    end

    def up(%{attribute: attribute}) do
      "remove #{inspect(attribute.source)}"
    end

    def down(%{attribute: attribute, multitenancy: multitenancy, commented?: true}) do
      prefix = """
      # This is the `down` migration of the statement:
      #
      #     remove #{inspect(attribute.source)}
      #
      """

      contents =
        %AshSqlite.MigrationGenerator.Operation.AddAttribute{
          attribute: attribute,
          multitenancy: multitenancy
        }
        |> AshSqlite.MigrationGenerator.Operation.AddAttribute.up()
        |> String.split("\n")
        |> Enum.map_join("\n", &"# #{&1}")

      prefix <> "\n" <> contents
    end

    def down(%{attribute: attribute, multitenancy: multitenancy, table: table}) do
      AshSqlite.MigrationGenerator.Operation.AddAttribute.up(
        %AshSqlite.MigrationGenerator.Operation.AddAttribute{
          attribute: attribute,
          table: table,
          multitenancy: multitenancy
        }
      )
    end
  end

  defmodule AddUniqueIndex do
    @moduledoc false
    defstruct [:identity, :table, :multitenancy, :old_multitenancy, no_phase: true]

    import Helper

    def up(%{
          identity:
            %{name: name, keys: keys, base_filter: base_filter, index_name: index_name} = identity,
          table: table,
          multitenancy: multitenancy
        }) do
      nils_distinct? = Map.get(identity, :nils_distinct?, true)

      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([multitenancy.attribute | keys])

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      if base_filter do
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], where: \"#{base_filter}\", #{join(["name: \"#{index_name}\"", option("nulls_distinct", nils_distinct?)])})"
      else
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\"", option("nulls_distinct", nils_distinct?)])})"
      end
    end

    def down(%{
          identity: %{name: name, keys: keys, index_name: index_name},
          table: table,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([multitenancy.attribute | keys])

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      "drop_if_exists unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end
  end

  defmodule AddCustomStatement do
    @moduledoc false
    defstruct [:statement, :table, no_phase: true]

    def up(%{statement: %{up: up, code?: false}}) do
      """
      execute(\"\"\"
      #{String.trim(up)}
      \"\"\")
      """
    end

    def up(%{statement: %{up: up, code?: true}}) do
      up
    end

    def down(%{statement: %{down: down, code?: false}}) do
      """
      execute(\"\"\"
      #{String.trim(down)}
      \"\"\")
      """
    end

    def down(%{statement: %{down: down, code?: true}}) do
      down
    end
  end

  defmodule RemoveCustomStatement do
    @moduledoc false
    defstruct [:statement, :table, no_phase: true]

    def up(%{statement: statement, table: table}) do
      AddCustomStatement.down(%AddCustomStatement{statement: statement, table: table})
    end

    def down(%{statement: statement, table: table}) do
      AddCustomStatement.up(%AddCustomStatement{statement: statement, table: table})
    end
  end

  defmodule AddCustomIndex do
    @moduledoc false
    defstruct [:table, :index, :base_filter, :multitenancy, no_phase: true]
    import Helper

    def up(%{
          index: index,
          table: table,
          base_filter: base_filter,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)])

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      index =
        if index.where && base_filter do
          %{index | where: base_filter <> " AND " <> index.where}
        else
          index
        end

      opts =
        join([
          option(:name, index.name),
          option(:unique, index.unique),
          option(:using, index.using),
          option(:where, index.where),
          option(:include, index.include)
        ])

      if opts == "",
        do: "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}])",
        else:
          "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{opts})"
    end

    def down(%{index: index, table: table, multitenancy: multitenancy}) do
      index_name = AshSqlite.CustomIndex.name(table, index)

      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)])

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      "drop_if_exists index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end
  end

  defmodule RemovePrimaryKey do
    @moduledoc false
    defstruct [:table, no_phase: true]

    def up(%{table: table}) do
      "drop constraint(#{inspect(table)}, \"#{table}_pkey\")"
    end

    def down(_) do
      ""
    end
  end

  defmodule RemovePrimaryKeyDown do
    @moduledoc false
    defstruct [:table, no_phase: true]

    def up(_) do
      ""
    end

    def down(%{table: table}) do
      "drop constraint(#{inspect(table)}, \"#{table}_pkey\")"
    end
  end

  defmodule RemoveCustomIndex do
    @moduledoc false
    defstruct [:table, :index, :base_filter, :multitenancy, no_phase: true]
    import Helper

    def up(%{index: index, table: table, multitenancy: multitenancy}) do
      index_name = AshSqlite.CustomIndex.name(table, index)

      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)])

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      "drop_if_exists index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end

    def down(%{
          index: index,
          table: table,
          base_filter: base_filter,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)])

          _ ->
            Enum.map(index.fields, &to_string/1)
        end

      index =
        if index.where && base_filter do
          %{index | where: base_filter <> " AND " <> index.where}
        else
          index
        end

      opts =
        join([
          option(:name, index.name),
          option(:unique, index.unique),
          option(:using, index.using),
          option(:where, index.where),
          option(:include, index.include)
        ])

      if opts == "" do
        "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}])"
      else
        "create index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{opts})"
      end
    end
  end

  defmodule RenameUniqueIndex do
    @moduledoc false
    defstruct [
      :new_identity,
      :old_identity,
      :table,
      :multitenancy,
      :old_multitenancy,
      no_phase: true
    ]

    alias AshSqlite.MigrationGenerator.Operation.AddUniqueIndex
    alias AshSqlite.MigrationGenerator.Operation.RemoveUniqueIndex

    def up(%{
          old_identity: old_identity,
          new_identity: new_identity,
          table: table,
          multitenancy: multitenancy,
          old_multitenancy: old_multitenancy
        }) do
      RemoveUniqueIndex.up(%{
        identity: old_identity,
        table: table,
        old_multitenancy: old_multitenancy
      }) <>
        "\n" <>
        AddUniqueIndex.up(%{identity: new_identity, table: table, multitenancy: multitenancy})
    end

    def down(%{
          old_identity: old_identity,
          new_identity: new_identity,
          table: table,
          multitenancy: multitenancy,
          old_multitenancy: old_multitenancy
        }) do
      RemoveUniqueIndex.up(%{
        identity: new_identity,
        table: table,
        old_multitenancy: multitenancy
      }) <>
        "\n" <>
        AddUniqueIndex.up(%{
          identity: old_identity,
          table: table,
          multitenancy: old_multitenancy
        })
    end
  end

  defmodule RemoveUniqueIndex do
    @moduledoc false
    defstruct [:identity, :table, :multitenancy, :old_multitenancy, no_phase: true]

    import Helper

    def up(%{
          identity: %{name: name, keys: keys, index_name: index_name},
          table: table,
          old_multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([multitenancy.attribute | keys])

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      "drop_if_exists unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
    end

    def down(%{
          identity: %{name: name, keys: keys, base_filter: base_filter, index_name: index_name},
          table: table,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            Enum.uniq([multitenancy.attribute | keys])

          _ ->
            keys
        end

      index_name = index_name || "#{table}_#{name}_index"

      if base_filter do
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], where: \"#{base_filter}\", #{join(["name: \"#{index_name}\""])})"
      else
        "create unique_index(:#{as_atom(table)}, [#{Enum.map_join(keys, ", ", &inspect/1)}], #{join(["name: \"#{index_name}\""])})"
      end
    end
  end

  defmodule AlterStrict do
    @moduledoc false
    # The table became STRICT, or stopped being. There is no statement for that: it takes a
    # rebuild.
    defstruct [:table, :from, :to]

    def reason(%{table: table, to: true}), do: "making `#{table}` a STRICT table"
    def reason(%{table: table, to: false}), do: "`#{table}` is no longer a STRICT table"
  end

  defmodule Omitted do
    @moduledoc false
    # A change SQLite cannot make in place, when tables are not rebuilt: only the hint knows of it.
    defstruct [:operation, :table, :multitenancy, :old_multitenancy]

    alias AshSqlite.MigrationGenerator.Operation

    def reason(%{operation: %Operation.AlterStrict{} = operation}, _multitenancy),
      do: Operation.AlterStrict.reason(operation)

    def reason(%{operation: operation}, multitenancy) do
      operation
      |> Map.put(:multitenancy, multitenancy)
      |> operation.__struct__.up()
      |> String.trim()
    end
  end

  defmodule RebuildTable do
    @moduledoc false
    # The operations of a table when one of them cannot be done in place (`requires_rebuild?/1`):
    # a `rebuild_table` of the table's new shape, followed by its indexes.
    defstruct [:table, :old_snapshot, :snapshot, :changes, no_phase: true]

    import Helper

    alias AshSqlite.MigrationGenerator.Operation

    def requires_rebuild?(%Operation.AlterAttribute{}), do: true
    def requires_rebuild?(%Operation.DropForeignKey{}), do: true
    def requires_rebuild?(%Operation.AlterDeferrability{}), do: true
    def requires_rebuild?(%Operation.RemovePrimaryKey{}), do: true
    def requires_rebuild?(%Operation.Omitted{}), do: true
    def requires_rebuild?(%Operation.AlterStrict{}), do: true

    def requires_rebuild?(%Operation.AddAttribute{attribute: attribute}),
      do: attribute.allow_nil? == false and attribute.default == "nil"

    def requires_rebuild?(_), do: false

    def up(%{old_snapshot: old, snapshot: new, changes: changes}) do
      renames = renames(changes)
      leftover = leftover_columns(old, new, renames, changes)

      render(%{
        table: new.table,
        from: old,
        from_columns: old.attributes,
        to: new,
        to_columns: new.attributes ++ Enum.map(leftover, &as_nullable/1),
        renames: renames,
        direction: :up,
        reasons: reasons(changes),
        notes: type_notes(old, new, changes) ++ leftover_notes(leftover) ++ statement_notes(old)
      })
    end

    def down(%{old_snapshot: old, snapshot: new, changes: changes}) do
      up_renames = renames(changes)
      leftover = leftover_columns(old, new, up_renames, changes)

      render(%{
        table: new.table,
        from: new,
        from_columns: new.attributes ++ Enum.map(leftover, &as_nullable/1),
        to: old,
        to_columns: old.attributes,
        renames: Map.new(up_renames, fn {to, from} -> {from, to} end),
        direction: :down,
        reasons: ["undoing the rebuild above (rows in columns it added are not kept)"],
        notes: statement_notes(new)
      })
    end

    defp render(%{table: table} = plan) do
      columns = plan.to_columns

      lines = plan.reasons ++ plan.notes ++ review_notes(columns, plan)

      options =
        [
          copy_option(columns, plan),
          if(plan.to.strict?, do: ~s|options: "STRICT"|)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join("", &(", " <> &1))

      adds =
        Enum.map_join(columns, "\n", fn attribute ->
          Operation.AddAttribute.up(%Operation.AddAttribute{
            attribute: attribute,
            table: table,
            multitenancy: plan.to.multitenancy,
            old_multitenancy: plan.from.multitenancy
          })
        end)

      [
        header(table, lines),
        Enum.map(plan.from.custom_statements, fn statement ->
          Operation.AddCustomStatement.down(%{statement: statement, table: table})
        end),
        "rebuild_table :#{as_atom(table)}#{options} do\n#{adds}\nend",
        Enum.map(plan.to.identities, fn identity ->
          Operation.AddUniqueIndex.up(%{
            identity: identity,
            table: table,
            multitenancy: plan.to.multitenancy
          })
        end),
        Enum.map(plan.to.custom_indexes, fn index ->
          Operation.AddCustomIndex.up(%{
            index: index,
            table: table,
            base_filter: plan.to.base_filter,
            multitenancy: plan.to.multitenancy
          })
        end),
        Enum.map(plan.to.custom_statements, fn statement ->
          Operation.AddCustomStatement.up(%{statement: statement, table: table})
        end)
      ]
      |> List.flatten()
      |> Enum.join("\n")
    end

    defp header(table, lines) do
      Enum.join(
        [
          "# SQLite cannot change `#{table}` in place, so it is rebuilt from the resource's",
          "# snapshot. Anything on the table that the resource does not describe (a column,",
          "# index or trigger added by hand) is not kept. Changes:"
          | Enum.flat_map(lines, &entry_lines/1)
        ],
        "\n"
      )
    end

    defp entry_lines(entry) do
      case String.split(entry, "\n") do
        [first | rest] -> ["# - #{first}" | Enum.map(rest, &"#   #{&1}")]
      end
    end

    # `copy: [subject: :title, name: "COALESCE(name, 'x')"]`: only what differs from copying
    # the column of the same name; nil when nothing does.
    defp copy_option(columns, plan) do
      entries =
        for column <- columns,
            from_name = Map.get(plan.renames, column.source, column.source),
            from_column = Enum.find(plan.from_columns, &(&1.source == from_name)),
            entry = copy_entry(column, from_name, from_column),
            do: entry

      if entries != [], do: "copy: [#{Enum.join(entries, ", ")}]"
    end

    defp copy_entry(column, from_name, from_column) do
      cond do
        expression = backfill(from_column, column, quote_name(from_name)) ->
          "#{atom_key(column.source)} #{inspect(expression)}"

        from_name == column.source ->
          nil

        true ->
          "#{atom_key(column.source)} :#{as_atom(from_name)}"
      end
    end

    defp atom_key(name), do: Macro.inspect_atom(:key, atom(name))

    defp atom(name) when is_atom(name), do: name
    # sobelow_skip ["DOS.StringToAtom"]
    defp atom(name), do: String.to_atom(name)

    defp backfill(%{allow_nil?: true}, %{allow_nil?: false} = column, expression) do
      case default_sql(column.default) do
        nil -> nil
        default -> "COALESCE(#{expression}, #{default})"
      end
    end

    defp backfill(_from, _to, _expression), do: nil

    defp review_notes(_columns, %{direction: :down}), do: []

    defp review_notes(columns, plan) do
      for column <- columns,
          note = review_note(column, plan) do
        note
      end
    end

    defp review_note(%{allow_nil?: false} = column, plan) do
      from_name = Map.get(plan.renames, column.source, column.source)

      case Enum.find(plan.from_columns, &(&1.source == from_name)) do
        nil ->
          if unfilled?(column),
            do: review_new_column(plan.table, column.source)

        %{allow_nil?: true} ->
          if default_sql(column.default) == nil,
            do: review_required_column(plan.table, column.source, from_name)

        _ ->
          nil
      end
    end

    defp review_note(_column, _plan), do: nil

    defp unfilled?(attribute), do: attribute.default == "nil" and !attribute.generated?

    defp review_required_column(table, name, from) do
      replaces = if from != name, do: " (in place of its `#{atom_key(name)} #{inspect(from)}`)"

      """
      REVIEW: #{inspect(name)} becomes required and has no default, so a row without a value for it
      stops this migration (nothing is changed). Give those rows one with the `copy:` option
      of `rebuild_table`#{replaces}, for example
        rebuild_table :#{as_atom(table)}, copy: [#{atom_key(name)} "COALESCE(#{from}, 'your value')"] do
      To give new rows one too, set a `default` on the attribute (or use `migration_defaults`)
      and regenerate.\
      """
    end

    defp review_new_column(table, name) do
      """
      REVIEW: #{inspect(name)} is new, required and has no default, so if the table has rows this
      migration stops (nothing is changed). Give the existing rows a value with the `copy:`
      option of `rebuild_table`, for example
        rebuild_table :#{as_atom(table)}, copy: [#{atom_key(name)} "'your value'"] do
      or set a `default` on the attribute (or use `migration_defaults`) and regenerate.\
      """
    end

    defp renames(changes) do
      for %Operation.RenameAttribute{old_attribute: old, new_attribute: new} <- changes,
          into: %{},
          do: {new.source, old.source}
    end

    # The columns of the old table that the resource no longer describes. They stay, as nullable
    # columns, unless the author asked for them to be dropped (`--drop-columns`).
    defp leftover_columns(old, new, renames, changes) do
      new_names = MapSet.new(new.attributes, & &1.source)
      renamed_away = MapSet.new(Map.values(renames))

      dropped =
        for %Operation.RemoveAttribute{attribute: attribute, commented?: false} <- changes,
            into: MapSet.new(),
            do: attribute.source

      Enum.reject(old.attributes, fn attribute ->
        MapSet.member?(new_names, attribute.source) or
          MapSet.member?(renamed_away, attribute.source) or
          MapSet.member?(dropped, attribute.source)
      end)
    end

    defp type_notes(_old, %{strict?: true}, _changes), do: []

    defp type_notes(old, _new, changes) do
      for %Operation.AlterAttribute{old_attribute: from, new_attribute: to} <- changes,
          from.type != to.type,
          Enum.any?(old.attributes, &(&1.source == from.source)) do
        "REVIEW: `#{to.source}` changes type in a table that is not STRICT, so values that " <>
          "do not convert are copied as they are, not rejected"
      end
    end

    defp statement_notes(%{custom_statements: []}), do: []

    defp statement_notes(%{custom_statements: statements}) do
      names = Enum.map_join(statements, ", ", &inspect(&1.name))

      [
        "REVIEW: the custom statements #{names} are dropped (their `down`) before and " <>
          "recreated (their `up`) after the rebuild.\n" <>
          "What they hold, such as the rows of a table or the contents of a full-text index, " <>
          "is not kept: to keep it, copy it before and restore it after, in this migration"
      ]
    end

    defp leftover_notes([]), do: []

    defp leftover_notes(leftover) do
      names = Enum.map_join(leftover, ", ", &inspect(&1.source))

      [
        "#{names} no longer in the resource, kept as nullable so no data is lost " <>
          "(to drop one, delete its line from the `rebuild_table` below)"
      ]
    end

    defp as_nullable(attribute) do
      %{attribute | allow_nil?: true, default: "nil", primary_key?: false, references: nil}
    end

    def reasons(changes), do: changes |> blocking_reasons() |> Enum.map(&elem(&1, 0))

    def blocking_reasons(changes) do
      for change <- changes,
          requires_rebuild?(change),
          !covered_by_other_change?(change, changes),
          reason = reason(change),
          uniq: true,
          do: {reason, blocks(change)}
    end

    defp blocks(%Operation.DropForeignKey{direction: :down}), do: :rollback
    defp blocks(_change), do: :run

    # Changing a foreign key is two operations, dropping it and altering the column. One line
    # says it: the drop when the column no longer has a foreign key (and the alteration is only
    # that), the alteration when it has another one.
    defp covered_by_other_change?(
           %Operation.DropForeignKey{attribute: %{source: source}},
           changes
         ) do
      Enum.any?(
        changes,
        &match?(%Operation.AlterAttribute{new_attribute: %{source: ^source, references: %{}}}, &1)
      )
    end

    defp covered_by_other_change?(
           %Operation.AlterAttribute{old_attribute: old, new_attribute: %{references: nil} = new},
           changes
         ) do
      Enum.any?(
        changes,
        &match?(
          %Operation.DropForeignKey{attribute: %{source: source}} when source == new.source,
          &1
        )
      ) and %{old | references: nil} == new
    end

    defp covered_by_other_change?(_change, _changes), do: false

    defp reason(%Operation.AlterAttribute{} = change),
      do: change |> Operation.AlterAttribute.up() |> String.trim()

    defp reason(%Operation.AddAttribute{attribute: attribute}) do
      "add #{inspect(attribute.source)} as NOT NULL without a default, " <>
        "which SQLite refuses on a table with rows"
    end

    defp reason(%Operation.AlterStrict{} = change), do: Operation.AlterStrict.reason(change)

    defp reason(%Operation.DropForeignKey{direction: :down, attribute: %{references: reference}}),
      do: "dropping the foreign key #{reference.name} when rolling back"

    defp reason(%Operation.DropForeignKey{attribute: %{references: reference}}),
      do: "dropping the foreign key #{reference.name}"

    defp reason(%Operation.RemovePrimaryKey{}), do: "changing the primary key"

    defp reason(%Operation.AlterDeferrability{references: %{name: name, deferrable: deferrable}})
         when deferrable not in [false, nil],
         do:
           "NOT APPLIED: the foreign key #{name} is deferrable " <>
             "(SQLite migrations cannot create DEFERRABLE constraints)"

    defp reason(%Operation.AlterDeferrability{}), do: nil

    defp quote_name(name), do: ~s("#{name}")

    defp default_sql(nil), do: nil
    defp default_sql("nil"), do: nil

    defp default_sql(code) when is_binary(code) do
      case Code.string_to_quoted(code) do
        {:ok, value} when is_binary(value) -> "'" <> String.replace(value, "'", "''") <> "'"
        {:ok, value} when is_number(value) -> to_string(value)
        {:ok, true} -> "1"
        {:ok, false} -> "0"
        {:ok, {:fragment, _, [sql]}} when is_binary(sql) -> sql
        _ -> nil
      end
    end
  end
end
