defmodule JarvisWeb.PageControllerTest do
  use JarvisWeb.ConnCase

  test "GET / renders workspace", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "JARVIS"
  end
end
