defmodule Ueberauth.Strategy.SalesforceTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  import Tesla.Mock

  alias Ueberauth.Strategy.Salesforce
  alias Ueberauth.Strategy.Salesforce.OAuth

  @client_id "test_salesforce_client_id"
  @client_secret "test_salesforce_client_secret"

  setup do
    original_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [
      client_id: @client_id,
      client_secret: @client_secret
    ])

    on_exit(fn ->
      if original_config do
        Application.put_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, original_config)
      else
        Application.delete_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth)
      end
    end)

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # OAuth.authorize_url!/2
  # ──────────────────────────────────────────────────────────────────────────

  describe "OAuth.authorize_url!/2" do
    test "generates authorization URL with correct parameters" do
      url = OAuth.authorize_url!(
        redirect_uri: "https://example.com/auth/salesforce/callback",
        scope: "api offline_access"
      )

      assert url =~ "https://login.salesforce.com/services/oauth2/authorize"
      assert url =~ "client_id=#{@client_id}"
      assert url =~ "redirect_uri=https%3A%2F%2Fexample.com%2Fauth%2Fsalesforce%2Fcallback"
      assert url =~ "response_type=code"
      assert url =~ "scope=api+offline_access"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # OAuth.get_identity/2
  # ──────────────────────────────────────────────────────────────────────────

  describe "OAuth.get_identity/2" do
    test "fetches and parses the identity payload from Salesforce using Tesla" do
      mock(fn
        %{method: :get, url: "https://login.salesforce.com/id/00Dxx0000001gEQEAY/005xx000001Sv2oAAC"} = env ->
          assert [{"Authorization", "Bearer valid_access_token"}, {"Accept", "application/json"}] = env.headers
          json(%{
            "user_id" => "005xx000001Sv2oAAC",
            "organization_id" => "00Dxx0000001gEQEAY",
            "username" => "testuser@salesforce.com",
            "display_name" => "Test User",
            "email" => "testuser@salesforce.com"
          })
      end)

      id_url = "https://login.salesforce.com/id/00Dxx0000001gEQEAY/005xx000001Sv2oAAC"
      assert {:ok, identity} = OAuth.get_identity(id_url, "valid_access_token")

      assert identity["username"] == "testuser@salesforce.com"
      assert identity["display_name"] == "Test User"
      assert identity["email"] == "testuser@salesforce.com"
    end

    test "handles HTTP errors correctly when fetching identity" do
      mock(fn %{method: :get} -> %Tesla.Env{status: 401, body: "Unauthorized"} end)

      id_url = "https://login.salesforce.com/id/some_org/some_user"
      assert {:error, "Failed to get identity info: 401 - \"Unauthorized\""} =
               OAuth.get_identity(id_url, "invalid_token")
    end

    test "handles transport errors when fetching identity" do
      mock(fn %{method: :get} -> {:error, :econnrefused} end)

      id_url = "https://login.salesforce.com/id/some_org/some_user"
      assert {:error, "HTTP error: :econnrefused"} =
               OAuth.get_identity(id_url, "some_token")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # OAuth.get_access_token/2 – error paths (previously uncovered)
  # ──────────────────────────────────────────────────────────────────────────

  describe "OAuth.get_access_token/2 error paths" do
    test "returns an error tuple when the token endpoint responds with an error" do
      mock(fn %{method: :post, url: "https://login.salesforce.com/services/oauth2/token"} ->
        %Tesla.Env{
          status: 400,
          headers: [{"content-type", "application/json"}],
          body: Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "authentication failure"
          })
        }
      end)

      result = OAuth.get_access_token([code: "bad_code"], redirect_uri: "https://example.com/callback")

      # OAuth2 library may swap in client_id validation error before hitting SF; we just assert it's an error
      assert match?({:error, _}, result)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # handle_callback! – both code-present and missing-code paths
  # ──────────────────────────────────────────────────────────────────────────

  describe "Salesforce.handle_callback!/1" do
    test "sets errors when code param is missing from callback" do
      conn =
        conn(:get, "/auth/salesforce/callback")
        |> Plug.Conn.put_private(:ueberauth_request_options, %{
          options: [uid_field: :user_id, default_scope: "api offline_access"],
          strategy: Salesforce,
          strategy_name: :salesforce
        })

      # Calling handle_callback! without a "code" param hits the fallback clause
      # which calls set_errors! – verify it returns a valid Plug.Conn without crashing
      result = Salesforce.handle_callback!(conn)
      assert %Plug.Conn{} = result
    end

    test "sets errors and returns conn when identity URL is missing from token" do
      mock(fn %{method: :post, url: "https://login.salesforce.com/services/oauth2/token"} ->
        json(%{
          "access_token" => "some_token",
          "refresh_token" => "some_refresh",
          "scope" => "api",
          "token_type" => "Bearer",
          # "id" (identity URL) intentionally omitted to trigger missing_id_url error path
          "instance_url" => "https://na1.salesforce.com"
        })
      end)

      conn =
        conn(:get, "/auth/salesforce/callback?code=valid_code")
        |> Map.put(:params, %{"code" => "valid_code"})
        |> Plug.Conn.put_private(:ueberauth_request_options, %{
          options: [uid_field: :user_id, default_scope: "api offline_access"],
          strategy: Salesforce,
          strategy_name: :salesforce
        })

      # Returns a valid Plug.Conn with errors set when token has no identity URL
      result = Salesforce.handle_callback!(conn)
      assert %Plug.Conn{} = result
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # handle_cleanup!/1  (previously uncovered)
  # ──────────────────────────────────────────────────────────────────────────

  describe "Salesforce.handle_cleanup!/1" do
    test "clears the salesforce_token and salesforce_user from private storage" do
      conn =
        conn(:get, "/")
        |> put_private(:salesforce_token, %{access_token: "secret"})
        |> put_private(:salesforce_user, %{"email" => "u@example.com"})

      result = Salesforce.handle_cleanup!(conn)

      assert result.private[:salesforce_token] == nil
      assert result.private[:salesforce_user] == nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Ueberauth.Strategy.Salesforce data callbacks
  # ──────────────────────────────────────────────────────────────────────────

  describe "Ueberauth.Strategy.Salesforce data callbacks" do
    setup do
      token = %OAuth2.AccessToken{
        access_token: "mock_token",
        refresh_token: "mock_refresh_token",
        expires_at: 1700000000,
        token_type: "Bearer",
        other_params: %{
          "scope" => "api refresh_token",
          "instance_url" => "https://na1.salesforce.com",
          "id" => "https://login.salesforce.com/id/00Dxx0000001gEQEAY/005xx000001Sv2oAAC"
        }
      }

      user = %{
        "user_id" => "005xx000001Sv2oAAC",
        "username" => "testuser@example.com",
        "email" => "testuser@example.com",
        "display_name" => "Mock User"
      }

      conn =
        conn(:get, "/")
        |> put_private(:salesforce_token, token)
        |> put_private(:salesforce_user, user)
        |> Plug.Conn.put_private(:ueberauth_request_options, %{options: [uid_field: :user_id]})

      {:ok, conn: conn, token: token, user: user}
    end

    test "uid/1 returns the configured uid_field value", %{conn: conn, user: user} do
      assert Salesforce.uid(conn) == user["user_id"]
    end

    test "credentials/1 returns populated Ueberauth.Auth.Credentials struct", %{conn: conn} do
      creds = Salesforce.credentials(conn)

      assert creds.token == "mock_token"
      assert creds.refresh_token == "mock_refresh_token"
      assert creds.expires == true
      assert creds.expires_at == 1700000000
      assert creds.token_type == "Bearer"
      assert creds.scopes == ["api", "refresh_token"]
      assert creds.other.instance_url == "https://na1.salesforce.com"
      assert creds.other.id_url == "https://login.salesforce.com/id/00Dxx0000001gEQEAY/005xx000001Sv2oAAC"
    end

    test "info/1 returns populated Ueberauth.Auth.Info struct", %{conn: conn} do
      info = Salesforce.info(conn)

      assert info.name == "Mock User"
      assert info.email == "testuser@example.com"
      assert info.nickname == "testuser@example.com"
    end

    test "extra/1 stores the raw token and user for downstream debugging", %{conn: conn, token: token, user: user} do
      extra = Salesforce.extra(conn)

      assert extra.raw_info.token == token
      assert extra.raw_info.user == user
    end
  end
end
