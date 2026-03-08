defmodule SocialScribe.AIContentGeneratorTest do
  use SocialScribe.DataCase, async: true

  import Tesla.Mock
  import SocialScribe.MeetingsFixtures
  import SocialScribe.BotsFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.AccountsFixtures

  alias SocialScribe.AIContentGenerator

  setup do
    user = user_fixture()
    calendar_event = calendar_event_fixture(%{user_id: user.id})
    bot = recall_bot_fixture(%{calendar_event_id: calendar_event.id, user_id: user.id})
    meeting = meeting_fixture(%{calendar_event_id: calendar_event.id, recall_bot_id: bot.id})
    
    _transcript = meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{
            "speaker" => "Alice",
            "words" => [%{"text" => "I'm"}, %{"text" => "the"}, %{"text" => "CEO"}]
          }
        ]
      }
    })

    _participant = meeting_participant_fixture(%{meeting_id: meeting.id, name: "Alice"})

    # Reload meeting to preload transcript since generate_prompt_for_meeting requires it
    meeting = SocialScribe.Meetings.get_meeting_with_details(meeting.id)

    {:ok, meeting: meeting}
  end

  describe "generate_crm_suggestions/3" do
    test "uses the generic extraction prompt when contact_context is nil", %{meeting: meeting} do
      mock(fn %{method: :post, url: url, body: raw_body} ->
        assert String.contains?(url, "generativelanguage.googleapis.com")
        
        body = Jason.decode!(raw_body)
        prompt_text = hd(hd(body["contents"])["parts"])["text"]

        # Assert generic fallback logic is preserved natively
        assert String.contains?(prompt_text, "IMPORTANT: Only extract information that is EXPLICITLY mentioned in the transcript.")
        refute String.contains?(prompt_text, "CRITICAL CONTEXT")

        json(%{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{
                    "text" => "```json\n[{\"field\": \"jobtitle\", \"value\": \"CEO\", \"context\": \"I'm the CEO\", \"timestamp\": \"00:00\"}]\n```"
                  }
                ]
              }
            }
          ]
        })
      end)

      assert {:ok, suggestions} = AIContentGenerator.generate_crm_suggestions(meeting, :salesforce, nil)
      
      assert length(suggestions) == 1
      assert hd(suggestions).field == "jobtitle"
      assert hd(suggestions).value == "CEO"
    end

    test "injects CRITICAL CONTEXT and explicit user boundaries when a contact_context is provided", %{meeting: meeting} do
      mock(fn %{method: :post, url: url, body: raw_body} ->
        assert String.contains?(url, "generativelanguage.googleapis.com")
        
        body = Jason.decode!(raw_body)
        prompt_text = hd(hd(body["contents"])["parts"])["text"]

        # Assert bug-fix specific injection to prevent AI hallucinations affecting multiple users
        assert String.contains?(prompt_text, "CRITICAL CONTEXT: You must ONLY extract information that belongs to or describes the contact named \"Alice Smith\" (Company: Acme Corp).")
        assert String.contains?(prompt_text, "IGNORE THEM COMPLETELY.")

        json(%{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{
                    "text" => "[\n  {\"field\": \"company\", \"value\": \"Acme Corp\", \"context\": \"I'm the CEO of Acme Corp\", \"timestamp\": \"00:00\"}\n]"
                  }
                ]
              }
            }
          ]
        })
      end)

      contact_context = %{
        firstname: "Alice",
        lastname: "Smith",
        company: "Acme Corp"
      }

      assert {:ok, suggestions} = AIContentGenerator.generate_crm_suggestions(meeting, :salesforce, contact_context)
      
      assert length(suggestions) == 1
      assert hd(suggestions).field == "company"
      assert hd(suggestions).value == "Acme Corp"
    end
  end
end
