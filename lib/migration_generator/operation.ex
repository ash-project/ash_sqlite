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
    defstruct [:table, :multitenancy, :old_multitenancy]
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
      with_match =
        if destination_attribute != reference_attribute do
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
    defstruct [:table, :references, :direction, no_phase: true]

    def up(%{direction: :up, table: table, references: %{name: name, deferrable: true}}) do
      "execute(\"ALTER TABLE #{table} alter CONSTRAINT #{name} DEFERRABLE INITIALLY IMMEDIATE\");"
    end

    def up(%{direction: :up, table: table, references: %{name: name, deferrable: :initially}}) do
      "execute(\"ALTER TABLE #{table} alter CONSTRAINT #{name} DEFERRABLE INITIALLY DEFERRED\");"
    end

    def up(%{direction: :up, table: table, references: %{name: name}}) do
      "execute(\"ALTER TABLE #{table} alter CONSTRAINT #{name} NOT DEFERRABLE\");"
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
      with_match =
        if destination_attribute != reference_attribute do
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
    # We only run this migration in one direction, based on the input
    # This is because the creation of a foreign key is handled by `references/3`
    # We only need to drop it before altering an attribute with `references/3`
    defstruct [:attribute, :table, :multitenancy, :direction, no_phase: true]

    import Helper

    def up(%{table: table, attribute: %{references: reference}, direction: :up}) do
      "drop constraint(:#{as_atom(table)}, #{join([inspect(reference.name)])})"
    end

    def up(_) do
      ""
    end

    def down(%{
          table: table,
          attribute: %{references: reference},
          direction: :down
        }) do
      "drop constraint(:#{as_atom(table)}, #{join([inspect(reference.name)])})"
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
          identity: %{name: name, keys: keys, base_filter: base_filter, index_name: index_name},
          table: table,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [multitenancy.attribute | keys]

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

    def down(%{
          identity: %{name: name, keys: keys, index_name: index_name},
          table: table,
          multitenancy: multitenancy
        }) do
      keys =
        case multitenancy.strategy do
          :attribute ->
            [multitenancy.attribute | keys]

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
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

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
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

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
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

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
            [to_string(multitenancy.attribute) | Enum.map(index.fields, &to_string/1)]

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

    def up(%{
          old_identity: %{index_name: old_index_name, name: old_name},
          new_identity: %{index_name: new_index_name},
          table: table
        }) do
      old_index_name = old_index_name || "#{table}_#{old_name}_index"

      "execute(\"ALTER INDEX #{old_index_name} " <>
        "RENAME TO #{new_index_name}\")\n"
    end

    def down(%{
          old_identity: %{index_name: old_index_name, name: old_name},
          new_identity: %{index_name: new_index_name},
          table: table
        }) do
      old_index_name = old_index_name || "#{table}_#{old_name}_index"

      "execute(\"ALTER INDEX #{new_index_name} " <>
        "RENAME TO #{old_index_name}\")\n"
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
            [multitenancy.attribute | keys]

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
            [multitenancy.attribute | keys]

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
end
