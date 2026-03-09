defmodule SocialScribe.Facebook do
  @behaviour SocialScribe.FacebookApi

  require Logger

  @base_url "https://graph.facebook.com/v22.0"

  @impl SocialScribe.FacebookApi
  def post_message_to_page(page_id, page_access_token, message) do
    body_params = %{
      message: message,
      access_token: page_access_token
    }

    case Tesla.post(client(), "/#{page_id}/feed", body_params) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        Logger.info(
          "Successfully posted to Facebook Page #{page_id}. Response ID: #{response_body["id"]}"
        )

        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error(
          "Facebook Page Post API Error (Page ID: #{page_id}, Status: #{status}): #{inspect(error_body)}"
        )

        message = get_in(error_body, ["error", "message"]) || "Unknown API error"
        {:error, {:api_error_posting, status, message, error_body}}

      {:error, reason} ->
        Logger.error("Facebook Page Post HTTP Error (Page ID: #{page_id}): #{inspect(reason)}")
        {:error, {:http_error_posting, reason}}
    end
  end

  @impl SocialScribe.FacebookApi
  def fetch_user_pages(user_id, user_access_token) do
    case Tesla.get(client(), "/#{user_id}/accounts?access_token=#{user_access_token}") do
      {:ok, %Tesla.Env{status: 200, body: %{"data" => pages_data}}} ->
        valid_pages =
          Enum.filter(pages_data, fn page ->
            Enum.member?(page["tasks"] || [], "CREATE_CONTENT") ||
              Enum.member?(page["tasks"] || [], "MANAGE")
          end)
          |> Enum.map(fn page ->
            %{
              id: page["id"],
              name: page["name"],
              category: page["category"],
              page_access_token: page["access_token"]
            }
          end)

        {:ok, valid_pages}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, "Failed to fetch user pages: #{status} - #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("Facebook fetch_user_pages HTTP error: #{inspect(reason)}")
        {:error, "Network error fetching pages"}
    end
  end

  @doc """
  Exchanges a short-lived user access token (1 hour) for a long-lived token (~60 days).

  This is Meta's documented best practice. Critically, when you subsequently call
  `/accounts` (fetch_user_pages) using a long-lived user token, the returned
  page_access_token for each page is **permanent** (never expires).

  Uses POST with a form-encoded body (not GET query params) so that `app_secret`
  and the exchange token are never written to server access logs or HTTP proxy logs.

  See: https://developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived
  """
  @impl SocialScribe.FacebookApi
  def exchange_for_long_lived_token(short_lived_token, app_id, app_secret) do
    params = [
      grant_type: "fb_exchange_token",
      client_id: app_id,
      client_secret: app_secret,
      fb_exchange_token: short_lived_token
    ]

    case Tesla.post(form_client(), "/oauth/access_token", params) do
      {:ok, %Tesla.Env{status: 200, body: %{"access_token" => long_lived_token}}} ->
        Logger.info("Successfully exchanged Facebook short-lived token for long-lived token")
        {:ok, long_lived_token}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        message = get_in(error_body, ["error", "message"]) || "Unknown error"
        Logger.error("Facebook token exchange failed (#{status}): #{message}")
        {:error, "Token exchange failed: #{message}"}

      {:error, reason} ->
        Logger.error("Facebook token exchange HTTP error: #{inspect(reason)}")
        {:error, "Network error during token exchange"}
    end
  end

  # Standard JSON client for Graph API calls
  defp client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @base_url},
      Tesla.Middleware.JSON
    ])
  end

  # Form-encoded client used for the token exchange endpoint.
  # Credentials are sent in the POST body, NOT in the URL query string,
  # so they never appear in access logs.
  defp form_client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @base_url},
      Tesla.Middleware.FormUrlencoded,
      Tesla.Middleware.JSON
    ])
  end
end
