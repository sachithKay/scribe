defmodule SocialScribeWeb.LandingLive do
  use SocialScribeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] do
      {:ok, push_navigate(socket, to: ~p"/dashboard")}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto text-center">
      <div class="bg-white/10 backdrop-blur-xl rounded-2xl border border-white/20 p-8 md:p-16 max-w-3xl mx-auto">
        <h1 class="text-4xl md:text-6xl font-bold mb-6 leading-tight">
          Turn Meetings into <span class="text-transparent bg-clip-text bg-gradient-to-r from-purple-400 via-pink-500 to-red-500">Masterpieces</span>.
        </h1>
        <p class="text-lg md:text-xl text-slate-600 mb-10 max-w-xl mx-auto">
          Social Scribe automatically transcribes your meetings, generates insightful follow-up emails, and crafts engaging social media posts. Save time, amplify your message.
        </p>
        <.link
          href={~p"/auth/google"}
          class="bg-white text-purple-700 font-bold py-4 px-10 rounded-lg shadow-xl hover:bg-slate-100 transition duration-300 ease-in-out transform hover:scale-105 text-lg"
        >
          Get Started for Free
        </.link>
        <p class="mt-6 text-sm text-slate-400">Connect your Google Calendar to begin.</p>
      </div>
    </div>
    """
  end
end
