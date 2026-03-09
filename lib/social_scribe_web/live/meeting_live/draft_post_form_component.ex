defmodule SocialScribeWeb.MeetingLive.DraftPostFormComponent do
  use SocialScribeWeb, :live_component
  import SocialScribeWeb.ClipboardButton

  require Logger

  alias SocialScribe.Poster

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        Draft Post
        <:subtitle>Generate a post based on insights from this meeting.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="draft-post-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="post"
      >
        <.input
          field={@form[:generated_content]}
          type="textarea"
          value={@automation_result.generated_content}
          class="bg-black"
        />

        <:actions>
          <.clipboard_button id="draft-post-button" text={@form[:generated_content].value} />

          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click={JS.patch(~p"/dashboard/meetings/#{@meeting}")}
              phx-disable-with="Cancelling..."
              class="bg-slate-100 text-slate-700 leading-none py-2 px-4 rounded-md"
            >
              Cancel
            </button>
            <.button type="submit" phx-disable-with="Posting...">Post</.button>
          </div>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(
        form: to_form(%{"generated_content" => assigns.automation_result.generated_content})
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, form: to_form(params))}
  end

  @impl true
  def handle_event("post", %{"generated_content" => generated_content}, socket) do
    case Poster.post_on_social_media(
           socket.assigns.automation.platform,
           generated_content,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Post successful")
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}

      {:error, {:api_error_posting, status, message, _body}} ->
        socket =
          socket
          |> put_flash(:error, "Failed to post (#{status}): #{message}")
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}

      {:error, {:http_error_posting, reason}} ->
        Logger.error("Social post network error: #{inspect(reason)}")

        socket =
          socket
          |> put_flash(:error, "Could not reach the social media service. Please try again.")
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}

      {:error, reason} when is_binary(reason) ->
        socket =
          socket
          |> put_flash(:error, reason)
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Unexpected social post error: #{inspect(reason)}")

        socket =
          socket
          |> put_flash(:error, "Something went wrong. Please try again.")
          |> push_patch(to: socket.assigns.patch)

        {:noreply, socket}
    end
  end
end
