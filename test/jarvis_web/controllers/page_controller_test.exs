defmodule JarvisWeb.PageControllerTest do
  use JarvisWeb.ConnCase

  test "GET / renders thread list", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Messages"
  end
end
