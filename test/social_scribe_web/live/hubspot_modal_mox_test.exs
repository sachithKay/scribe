defmodule SocialScribeWeb.HubspotModalMoxTest do
  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import Mox

  setup :verify_on_exit!

  describe "HubSpot Modal with mocked API" do
    setup %{conn: conn} do
      user = user_fixture()
      hubspot_credential = hubspot_credential_fixture(%{user_id: user.id})
      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting,
        hubspot_credential: hubspot_credential
      }
    end

    test "search_contacts returns mocked results", %{conn: conn, meeting: meeting} do
      mock_contacts = [
        %{
          id: "123",
          firstname: "John",
          lastname: "Doe",
          email: "john@example.com",
          phone: nil,
          company: "Acme Corp",
          display_name: "John Doe"
        },
        %{
          id: "456",
          firstname: "Jane",
          lastname: "Smith",
          email: "jane@example.com",
          phone: "555-1234",
          company: "Tech Inc",
          display_name: "Jane Smith"
        }
      ]

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, query ->
        assert query == "John"
        {:ok, mock_contacts}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      # Trigger contact search
      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      # Wait for async update
      :timer.sleep(200)

      # Re-render to see updates
      html = render(view)

      # Verify contacts are displayed
      assert html =~ "John Doe"
      assert html =~ "Jane Smith"
    end

    test "search_contacts handles API error gracefully", %{conn: conn, meeting: meeting} do
      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:error, {:api_error, 500, %{"message" => "Internal server error"}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Test"})

      :timer.sleep(200)

      html = render(view)

      # Should show error message
      assert html =~ "Failed to search contacts"
    end

    test "selecting contact triggers suggestion generation", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "123",
        firstname: "John",
        lastname: "Doe",
        email: "john@example.com",
        phone: nil,
        company: "Acme Corp",
        display_name: "John Doe"
      }

      mock_suggestions = [
        %{
          field: "phone",
          value: "555-1234",
          context: "Mentioned phone number"
        }
      ]

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      # Also need to mock the AI content generator for suggestions
      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _meeting ->
        {:ok, mock_suggestions}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      # Search for contact
      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "John"})

      :timer.sleep(200)

      # Select the contact (it's a button, not li)
      view
      |> element("button[phx-click='select_contact'][phx-value-id='123']")
      |> render_click()

      :timer.sleep(500)

      # After selecting contact, suggestions should be generated
      # Modal should still be present
      assert has_element?(view, "#hubspot-modal-wrapper")
    end

    test "contact dropdown shows search results", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "789",
        firstname: "Test",
        lastname: "User",
        email: "test@example.com",
        phone: nil,
        company: nil,
        display_name: "Test User"
      }

      SocialScribe.HubspotApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/hubspot")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Test"})

      :timer.sleep(200)

      html = render(view)

      # Verify contact appears in dropdown
      assert html =~ "Test User"
      assert html =~ "test@example.com"
    end
  end



  # Helper function to create a meeting with transcript for testing
  defp meeting_fixture_with_transcript(user) do
    meeting = meeting_fixture(%{})

    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)

    {:ok, _updated_event} =
      SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{
            "speaker" => "John Doe",
            "words" => [
              %{"text" => "Hello,"},
              %{"text" => "my"},
              %{"text" => "phone"},
              %{"text" => "is"},
              %{"text" => "555-1234"}
            ]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end
end
