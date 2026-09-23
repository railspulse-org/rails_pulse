require "test_helper"

class StoragePageTest < ApplicationSystemTestCase
  fixtures :rails_pulse_routes, :rails_pulse_queries, :rails_pulse_summaries,
           :rails_pulse_requests, :rails_pulse_operations

  test "dashboard storage panel links to the storage page" do
    visit_rails_pulse_path "/"

    assert_selector ".storage-panel-stats"
    assert_text "HIGHEST FILL"
    assert_text "RECORDS"
    assert_text "CLEANUP"

    find("a[href='/rails_pulse/storage']", match: :first).click

    assert_current_path "/rails_pulse/storage"
    assert_text "Operations"
    assert_text "Requests"
    assert_text "TABLES"
    assert_text "CLEANUP"
    assert_text "DATABASE"

    # Tracking writers panel: live background writers from heartbeat fixtures
    assert_text "TRACKING WRITERS"
    assert_text "Live writers"
    assert_text "web-1:101"
  end
end
