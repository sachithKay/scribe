defmodule SocialScribe.Ueberauth.Strategy.LinkedIn do
  @moduledoc """
  LinkedIn Strategy for Ueberauth using OpenID Connect.

  Note: This custom strategy replaces the default `ueberauth_linkedin` to 
  support LinkedIn's modern OpenID Connect (OIDC) flow and endpoints 
  (`/v2/userinfo`). It uses the custom `SocialScribe.Ueberauth.Strategy.LinkedIn.OAuth`
  client to prevent security leaks during the token exchange phase.
  """
  use Ueberauth.Strategy,
    uid_field: :sub,
    default_scope: "openid profile email w_member_social"

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @userinfo_url "https://api.linkedin.com/v2/userinfo"

  @doc """
  Handles the setup phase of the strategy.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    opts =
      [scope: scopes]
      |> with_state_param(conn)

    redirect!(conn, SocialScribe.Ueberauth.Strategy.LinkedIn.OAuth.authorize_url!(opts))
  end

  @doc """
  Handles the callback phase.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    params = [code: code, redirect_uri: callback_url(conn)]
    token = SocialScribe.Ueberauth.Strategy.LinkedIn.OAuth.get_token!(params)

    if token.access_token == nil do
      set_errors!(conn, [
        error(token.other_params["error"], token.other_params["error_description"])
      ])
    else
      fetch_user(conn, token)
    end
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up the connection after the strategy is done.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:linkedin_token, nil)
    |> put_private(:linkedin_user, nil)
  end

  @doc """
  Fetches the user's ID from the response.
  """
  def uid(conn) do
    user = conn.private.linkedin_user
    user["sub"]
  end

  @doc """
  Fetches the user's info from the response.
  """
  def info(conn) do
    user = conn.private.linkedin_user

    %Info{
      name: user["name"],
      first_name: user["given_name"],
      last_name: user["family_name"],
      email: user["email"],
      image: user["picture"]
    }
  end

  @doc """
  Fetches the user's credentials from the response.
  """
  def credentials(conn) do
    token = conn.private.linkedin_token
    scopes = (token.other_params["scope"] || "") |> String.split(",")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes
    }
  end

  @doc """
  Fetches extra information about the user.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.linkedin_token,
        user: conn.private.linkedin_user
      }
    }
  end

  defp fetch_user(conn, token) do
    case SocialScribe.Ueberauth.Strategy.LinkedIn.OAuth.get(token, @userinfo_url) do
      {:ok, %OAuth2.Response{status_code: 200, body: user}} ->
        conn
        |> put_private(:linkedin_token, token)
        |> put_private(:linkedin_user, user)

      {:ok, %OAuth2.Response{status_code: status, body: body}} ->
        set_errors!(conn, [error("api_error", "Status: #{status}, Body: #{inspect(body)}")])

      {:error, reason} ->
        set_errors!(conn, [error("network_error", inspect(reason))])
    end
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end
end
