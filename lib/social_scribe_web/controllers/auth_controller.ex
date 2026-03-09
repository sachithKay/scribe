defmodule SocialScribeWeb.AuthController do
  use SocialScribeWeb, :controller

  alias SocialScribe.FacebookApi
  alias SocialScribe.Accounts
  alias SocialScribeWeb.UserAuth
  plug Ueberauth

  require Logger

  @doc """
  Handles the initial request to the provider (e.g., Google).
  Ueberauth's plug will redirect the user to the provider's consent page.
  """
  def request(conn, _params) do
    render(conn, :request)
  end

  @doc """
  Handles the callback from the provider after the user has granted consent.
  """
  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "google"
      })
      when not is_nil(user) do


    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, "Google account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Google account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "linkedin"
      }) do


    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, _credential} ->


        conn
        |> put_flash(:info, "LinkedIn account added successfully.")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, _reason} ->


        conn
        |> put_flash(:error, "Could not add LinkedIn account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "facebook"
      })
      when not is_nil(user) do


    case Accounts.find_or_create_user_credential(user, auth) do
      {:ok, credential} ->
        # Exchange the short-lived user token (1h) for a long-lived token (~60 days).
        # Pages fetched using a long-lived user token return PERMANENT page_access_tokens.
        # This is Meta's documented production approach.
        # See: https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived
        app_id = Application.get_env(:ueberauth, Ueberauth.Strategy.Facebook.OAuth)[:client_id]
        app_secret = Application.get_env(:ueberauth, Ueberauth.Strategy.Facebook.OAuth)[:client_secret]

        effective_token =
          case FacebookApi.exchange_for_long_lived_token(credential.token, app_id, app_secret) do
            {:ok, long_lived_token} ->
              # Persist the long-lived token so future page fetches also use it
              case Accounts.update_user_credential(credential, %{token: long_lived_token}) do
                {:ok, _} -> :ok
                {:error, reason} ->
                  Logger.error("Failed to persist long-lived Facebook token for user #{credential.user_id}: #{inspect(reason)}")
              end

              long_lived_token

            {:error, reason} ->
              Logger.warning("Could not exchange for long-lived Facebook token: #{reason}. Using short-lived token.")
              credential.token
          end

        case FacebookApi.fetch_user_pages(credential.uid, effective_token) do
          {:ok, facebook_pages} ->
            Enum.each(facebook_pages, fn page ->
              Accounts.link_facebook_page(user, credential, page)
            end)

          {:error, reason} ->
            Logger.warning("Could not fetch Facebook pages after OAuth: #{reason}")
        end

        conn
        |> put_flash(
          :info,
          "Facebook account added successfully. Please select a page to connect."
        )
        |> redirect(to: ~p"/dashboard/settings/facebook_pages")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not add Facebook account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "hubspot"
      })
      when not is_nil(user) do


    hub_id = to_string(auth.uid)

    credential_attrs = %{
      user_id: user.id,
      provider: "hubspot",
      uid: hub_id,
      token: auth.credentials.token,
      refresh_token: auth.credentials.refresh_token,
      expires_at:
        (auth.credentials.expires_at && DateTime.from_unix!(auth.credentials.expires_at)) ||
          DateTime.add(DateTime.utc_now(), 3600, :second),
      email: auth.info.email
    }

    case Accounts.find_or_create_hubspot_credential(user, credential_attrs) do
      {:ok, _credential} ->
        Logger.info("HubSpot account connected for user #{user.id}, hub_id: #{hub_id}")

        conn
        |> put_flash(:info, "HubSpot account connected successfully!")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error("Failed to save HubSpot credential: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not connect HubSpot account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth, current_user: user}} = conn, %{
        "provider" => "salesforce"
      })
      when not is_nil(user) do


    salesforce_uid = to_string(auth.uid)

    credential_attrs = %{
      user_id: user.id,
      provider: "salesforce",
      uid: salesforce_uid,
      token: auth.credentials.token,
      refresh_token: auth.credentials.refresh_token,
      expires_at:
        (auth.credentials.expires_at && DateTime.from_unix!(auth.credentials.expires_at)) ||
          DateTime.add(DateTime.utc_now(), 3600, :second),
      email: auth.info.email,
      instance_url: auth.credentials.other.instance_url
    }

    case Accounts.find_or_create_salesforce_credential(user, credential_attrs) do
      {:ok, _credential} ->
        Logger.info("Salesforce account connected for user #{user.id}, uid: #{salesforce_uid}")

        conn
        |> put_flash(:info, "Salesforce account connected successfully!")
        |> redirect(to: ~p"/dashboard/settings")

      {:error, reason} ->
        Logger.error("Failed to save Salesforce credential: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not connect Salesforce account.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do


    case Accounts.find_or_create_user_from_oauth(auth) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)

      {:error, reason} ->
        Logger.error("Failed to sign in user via OAuth: #{inspect(reason)}")

        conn
        |> put_flash(:error, "There was an error signing you in.")
        |> redirect(to: ~p"/")
    end
  end


  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    provider = String.capitalize(conn.params["provider"] || "account")
    
    # Log the full failure struct (contains OAuth error codes and descriptions).
    # This is critical for diagnosing issues like redirect_uri mismatches or invalid client secrets.
    Logger.error("#{provider} OAuth Failure Details: #{inspect(failure)}")

    case conn.assigns[:current_user] do
      nil ->
        # User was likely trying to Sign In and failed. Send to landing page.
        conn
        |> put_flash(:error, "Failed to connect #{provider}. Please try again.")
        |> redirect(to: ~p"/")

      _user ->
        # User was already logged in and trying to Link an account.
        # Send back to settings so they don't lose their session context.
        conn
        |> put_flash(:error, "Failed to connect #{provider}. Please try again.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end

  def callback(conn, _params) do
    Logger.error("Unknown OAuth Callback State")

    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_flash(:error, "There was an error signing you in. Please try again.")
        |> redirect(to: ~p"/")

      _user ->
        conn
        |> put_flash(:error, "There was an error with the authentication request.")
        |> redirect(to: ~p"/dashboard/settings")
    end
  end
end
