defmodule AshSqlite.Test.UpdateTest do
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.Post

  require Ash.Query

  test "updating a record when multiple records are in the table will only update the desired record" do
    # This test is here because of a previous bug in update that caused
    # all records in the table to be updated.
    id_1 = Ash.UUID.generate()
    id_2 = Ash.UUID.generate()

    new_post_1 =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id_1,
        title: "new_post_1"
      })
      |> Ash.create!()

    _new_post_2 =
      Post
      |> Ash.Changeset.for_create(:create, %{
        id: id_2,
        title: "new_post_2"
      })
      |> Ash.create!()

    {:ok, updated_post_1} =
      new_post_1
      |> Ash.Changeset.for_update(:update, %{
        title: "new_post_1_updated"
      })
      |> Ash.update()

    # It is deliberate that post 2 is re-fetched from the db after the
    # update to post 1. This ensure that post 2 was not updated.
    post_2 = Ash.get!(Post, id_2)

    assert updated_post_1.id == id_1
    assert updated_post_1.title == "new_post_1_updated"

    assert post_2.id == id_2
    assert post_2.title == "new_post_2"
  end
end
