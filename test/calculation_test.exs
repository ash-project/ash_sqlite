defmodule AshSqlite.CalculationTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Account, Api, Author, Comment, Post, User}

  require Ash.Query

  test "calculations can refer to embedded attributes" do
    author =
      Author
      |> Ash.Changeset.for_create(:create, %{bio: %{title: "Mr.", bio: "Bones"}})
      |> Api.create!()

    assert %{title: "Mr."} =
             Author
             |> Ash.Query.filter(id == ^author.id)
             |> Ash.Query.load(:title)
             |> Api.read_one!()
  end

  test "calculations can use the || operator" do
    author =
      Author
      |> Ash.Changeset.for_create(:create, %{bio: %{title: "Mr.", bio: "Bones"}})
      |> Api.create!()

    assert %{first_name_or_bob: "bob"} =
             Author
             |> Ash.Query.filter(id == ^author.id)
             |> Ash.Query.load(:first_name_or_bob)
             |> Api.read_one!()
  end

  test "calculations can use the && operator" do
    author =
      Author
      |> Ash.Changeset.for_create(:create, %{
        first_name: "fred",
        bio: %{title: "Mr.", bio: "Bones"}
      })
      |> Api.create!()

    assert %{first_name_and_bob: "bob"} =
             Author
             |> Ash.Query.filter(id == ^author.id)
             |> Ash.Query.load(:first_name_and_bob)
             |> Api.read_one!()
  end

  test "concat calculation can be filtered on" do
    author =
      Author
      |> Ash.Changeset.new(%{first_name: "is", last_name: "match"})
      |> Api.create!()

    Author
    |> Ash.Changeset.new(%{first_name: "not", last_name: "match"})
    |> Api.create!()

    author_id = author.id

    assert %{id: ^author_id} =
             Author
             |> Ash.Query.load(:full_name)
             |> Ash.Query.filter(full_name == "is match")
             |> Api.read_one!()
  end

  test "conditional calculations can be filtered on" do
    author =
      Author
      |> Ash.Changeset.new(%{first_name: "tom"})
      |> Api.create!()

    Author
    |> Ash.Changeset.new(%{first_name: "tom", last_name: "holland"})
    |> Api.create!()

    author_id = author.id

    assert %{id: ^author_id} =
             Author
             |> Ash.Query.load([:conditional_full_name, :full_name])
             |> Ash.Query.filter(conditional_full_name == "(none)")
             |> Api.read_one!()
  end

  test "parameterized calculations can be filtered on" do
    Author
    |> Ash.Changeset.new(%{first_name: "tom", last_name: "holland"})
    |> Api.create!()

    assert %{param_full_name: "tom holland"} =
             Author
             |> Ash.Query.load(:param_full_name)
             |> Api.read_one!()

    assert %{param_full_name: "tom~holland"} =
             Author
             |> Ash.Query.load(param_full_name: [separator: "~"])
             |> Api.read_one!()

    assert %{} =
             Author
             |> Ash.Query.filter(param_full_name(separator: "~") == "tom~holland")
             |> Api.read_one!()
  end

  test "parameterized related calculations can be filtered on" do
    author =
      Author
      |> Ash.Changeset.new(%{first_name: "tom", last_name: "holland"})
      |> Api.create!()

    Comment
    |> Ash.Changeset.new(%{title: "match"})
    |> Ash.Changeset.manage_relationship(:author, author, type: :append_and_remove)
    |> Api.create!()

    assert %{title: "match"} =
             Comment
             |> Ash.Query.filter(author.param_full_name(separator: "~") == "tom~holland")
             |> Api.read_one!()

    assert %{title: "match"} =
             Comment
             |> Ash.Query.filter(
               author.param_full_name(separator: "~") == "tom~holland" and
                 author.param_full_name(separator: " ") == "tom holland"
             )
             |> Api.read_one!()
  end

  test "parameterized calculations can be sorted on" do
    Author
    |> Ash.Changeset.new(%{first_name: "tom", last_name: "holland"})
    |> Api.create!()

    Author
    |> Ash.Changeset.new(%{first_name: "abc", last_name: "def"})
    |> Api.create!()

    assert [%{first_name: "abc"}, %{first_name: "tom"}] =
             Author
             |> Ash.Query.sort(param_full_name: [separator: "~"])
             |> Api.read!()
  end

  test "calculations using if and literal boolean results can run" do
    Post
    |> Ash.Query.load(:was_created_in_the_last_month)
    |> Ash.Query.filter(was_created_in_the_last_month == true)
    |> Api.read!()
  end

  test "nested conditional calculations can be loaded" do
    Author
    |> Ash.Changeset.new(%{last_name: "holland"})
    |> Api.create!()

    Author
    |> Ash.Changeset.new(%{first_name: "tom"})
    |> Api.create!()

    assert [%{nested_conditional: "No First Name"}, %{nested_conditional: "No Last Name"}] =
             Author
             |> Ash.Query.load(:nested_conditional)
             |> Ash.Query.sort(:nested_conditional)
             |> Api.read!()
  end

  test "loading a calculation loads its dependent loads" do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{is_active: true})
      |> Api.create!()

    account =
      Account
      |> Ash.Changeset.for_create(:create, %{is_active: true})
      |> Ash.Changeset.manage_relationship(:user, user, type: :append_and_remove)
      |> Api.create!()
      |> Api.load!([:active])

    assert account.active
  end

  # describe "string join expression" do
  #   test "no nil values" do
  #     author =
  #       Author
  #       |> Ash.Changeset.for_create(:create, %{
  #         first_name: "Bill",
  #         last_name: "Jones",
  #         bio: %{title: "Mr.", bio: "Bones"}
  #       })
  #       |> Api.create!()

  #     assert %{
  #              full_name_with_nils: "Bill Jones",
  #              full_name_with_nils_no_joiner: "BillJones"
  #            } =
  #              Author
  #              |> Ash.Query.filter(id == ^author.id)
  #              |> Ash.Query.load(:full_name_with_nils)
  #              |> Ash.Query.load(:full_name_with_nils_no_joiner)
  #              |> Api.read_one!()
  #   end

  #   test "with nil value" do
  #     author =
  #       Author
  #       |> Ash.Changeset.for_create(:create, %{
  #         first_name: "Bill",
  #         bio: %{title: "Mr.", bio: "Bones"}
  #       })
  #       |> Api.create!()

  #     Logger.configure(level: :debug)

  #     assert %{
  #              full_name_with_nils: "Bill",
  #              full_name_with_nils_no_joiner: "Bill"
  #            } =
  #              Author
  #              |> Ash.Query.filter(id == ^author.id)
  #              |> Ash.Query.load(:full_name_with_nils)
  #              |> Ash.Query.load(:full_name_with_nils_no_joiner)
  #              |> Api.read_one!()
  #   end
  # end

  describe "-/1" do
    test "makes numbers negative" do
      Post
      |> Ash.Changeset.new(%{title: "match", score: 42})
      |> Api.create!()

      assert [%{negative_score: -42}] =
               Post
               |> Ash.Query.load(:negative_score)
               |> Api.read!()
    end
  end

  describe "maps" do
    test "maps can be constructed" do
      Post
      |> Ash.Changeset.new(%{title: "match", score: 42})
      |> Api.create!()

      assert [%{score_map: %{negative_score: %{foo: -42}}}] =
               Post
               |> Ash.Query.load(:score_map)
               |> Api.read!()
    end
  end

  test "dependent calc" do
    post =
      Post
      |> Ash.Changeset.new(%{title: "match", price: 10_024})
      |> Api.create!()

    Post.get_by_id(post.id,
      query: Post |> Ash.Query.select([:id]) |> Ash.Query.load([:price_string_with_currency_sign])
    )
  end

  test "nested get_path works" do
    assert "thing" =
             Post
             |> Ash.Changeset.new(%{title: "match", price: 10_024, stuff: %{foo: %{bar: "thing"}}})
             |> Ash.Changeset.deselect(:stuff)
             |> Api.create!()
             |> Api.load!(:foo_bar_from_stuff)
             |> Map.get(:foo_bar_from_stuff)
  end

  test "runtime expression calcs" do
    author =
      Author
      |> Ash.Changeset.for_create(:create, %{
        first_name: "Bill",
        last_name: "Jones",
        bio: %{title: "Mr.", bio: "Bones"}
      })
      |> Api.create!()

    assert %AshSqlite.Test.Money{} =
             Post
             |> Ash.Changeset.new(%{title: "match", price: 10_024})
             |> Ash.Changeset.manage_relationship(:author, author, type: :append_and_remove)
             |> Api.create!()
             |> Api.load!(:calc_returning_json)
             |> Map.get(:calc_returning_json)

    assert [%AshSqlite.Test.Money{}] =
             author
             |> Api.load!(posts: :calc_returning_json)
             |> Map.get(:posts)
             |> Enum.map(&Map.get(&1, :calc_returning_json))
  end
end
