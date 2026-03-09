defmodule SocialScribe.LinkedIn do
  require Logger

  @behaviour SocialScribe.LinkedInApi

  @linkedin_api_base_url "https://api.linkedin.com/v2"

  @impl SocialScribe.LinkedInApi
  def post_text_share(token, author_urn, text_content) do
    body =
      %{
        "author" => author_urn,
        "lifecycleState" => "PUBLISHED",
        "specificContent" => %{
          "com.linkedin.ugc.ShareContent" => %{
            "shareCommentary" => %{
              "text" => text_content
            },
            "shareMediaCategory" => "NONE"
          }
        },
        "visibility" => %{
          "com.linkedin.ugc.MemberNetworkVisibility" => "PUBLIC"
        }
      }

    case Tesla.post(client(token), "/ugcPosts", body) do
      # HTTP 201 Created is success
      {:ok, %Tesla.Env{status: 201, body: response_body}} ->
        Logger.info("Successfully posted to LinkedIn. Response ID: #{response_body["id"]}")
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.error("LinkedIn API Error (Status: #{status}): #{inspect(error_body)}")
        message = get_in(error_body, ["message"]) || "Unknown API error"
        {:error, {:api_error_posting, status, message, error_body}}

      {:error, reason} ->
        Logger.error("LinkedIn HTTP Error: #{inspect(reason)}")
        {:error, {:http_error_posting, reason}}
    end
  end

  defp client(token) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @linkedin_api_base_url},
      {Tesla.Middleware.Headers,
       [{"Authorization", "Bearer #{token}"}, {"X-Restli-Protocol-Version", "2.0.0"}]},
      Tesla.Middleware.JSON
    ])
  end
end
