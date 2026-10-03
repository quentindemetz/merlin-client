# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ratatui_ruby"
require "ratatui_ruby/test_helper"
require_relative "../lib/merlin/tui"
require_relative "fake_speaker"

class TUITest < Minitest::Test
  include RatatuiRuby::TestHelper

  # In-memory stand-in for Merlin::Backend recording every call.
  class FakeBackend
    attr_accessor :setting_id, :speakers_list
    attr_reader :calls

    def initialize(logged_in: true)
      @logged_in = logged_in
      @calls = []
      @basket = []
      @speakers_list = [{ "id" => "s1", "speaker_name" => "Chambre" }]
    end

    def logged_in? = @logged_in

    # Simulates the laptop being on the speaker's (internet-less) Wi-Fi.
    attr_accessor :online

    def reachable? = @online != false

    def login(email, password)
      @calls << [:login, email, password]
      raise Merlin::BackendError, "authentication failed" if password == "bad"

      @logged_in = true
    end

    def logout
      @calls << [:logout]
      @logged_in = false
    end

    def speakers = @speakers_list
    def home_page_id = "home"
    def selections
      raise Merlin::OfflineError, "can't reach api.hello-merlin.com" unless reachable?

      @basket
    end

    def page(id)
      @calls << [:page, id]
      { "title" => "Accueil", "modules" => [
        { "format" => "taxon_slider", "title" => "Univers", "items" => [{ "id" => "t1", "title" => "Contes" }] },
        { "format" => "selection_slider", "title" => "Nouveautés",
          "elements" => [{ "collection" => { "id" => "c1", "title" => "Odyssées", "nb_episode" => 2 } }] }
      ] }
    end

    def taxonomy(id) = { "title" => "Contes", "elements" => [{ "content" => { "id" => "k9", "title" => "Le loup" } }] }

    def collection(id)
      @calls << [:collection, id]
      { "id" => id, "title" => "Odyssées", "description" => "Histoires", "contents" => [
        { "id" => "k2", "title" => "Puyi", "episode" => 2, "duration" => 600 },
        { "id" => "k1", "title" => "Robinson", "episode" => 1, "duration" => 61 }
      ] }
    end

    def speaker_library
      { "treeStructure" => [{ "uuid" => "f", "title" => "Contes", "child" => [
        { "uuid" => "a1", "title" => "Ours brun" }, { "uuid" => "a2", "title" => "Le loup" }
      ] }] }
    end

    def select_contents(ids, add: true)
      @calls << [:select, ids, add]
      @basket += ids.map { |i| { "add" => add, "content" => { "id" => i, "title" => "T#{i}" } } }
    end

    def select_collection(id)
      @calls << [:select_collection, id]
      @basket
    end

    def cancel_selections(ids)
      @calls << [:cancel, ids]
      @basket.reject! { |e| ids.include?(e.dig("content", "id")) }
      @basket
    end

    def search(q) = [{ "content" => { "id" => "k5", "title" => "Petit ours #{q}" } }]

    # --- synchro endpoints (used with the real Merlin::Sync) ---
    attr_reader :reports

    def create_synchro(type:)
      offline_guard!
      { "id" => "syn-tui", "type" => type, "ssid" => "MERLIN_TUI", "password" => "pw",
        "fileList" => [{ "type" => "image", "url" => "https://cdn/i.jpg", "filename" => "i.jpg", "title" => "Img" },
                       { "type" => "audio", "url" => "https://cdn/a.mp3", "filename" => "a.mp3", "title" => "Le loup" }],
        "playlistText" => '[{"uuid":"a","title":"Le loup"}]' }
    end

    def download(url, dest)
      offline_guard!
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, "data for #{url}" * 100)
    end

    def report_synchro(id, body)
      offline_guard!
      (@reports ||= []) << [id, body]
    end

    private

    def offline_guard!
      raise Merlin::OfflineError, "can't reach api.hello-merlin.com" unless reachable?
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @config = Merlin::Config.new(@dir)
  end

  def teardown = FileUtils.rm_rf(@dir)

  # No real firewall in tests: isolation is off unless a test provides one.
  def app(backend, isolation_factory: ->(out:) { nil }, **)
    Merlin::TUI::App.new(backend: backend, config: @config, isolation_factory: isolation_factory, **)
  end

  class RecordingIsolation
    attr_reader :calls

    def initialize = @calls = []
    def authorize! = @calls << :authorize
    def enable! = @calls << :enable
    def disable! = @calls << :disable
    def active? = @calls.last == :enable
  end

  def test_sync_asks_for_admin_rights_once_and_filters_traffic
    @config.setting_id = "s1"
    speaker = FakeSpeaker.new
    backend = FakeBackend.new
    iso = RecordingIsolation.new
    sync_screen = nil
    stop = lambda do |a|
      sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
      s = sync_screen&.session
      inject_keys(:enter) if s&.wifi&.waiting && screen_text.include?("MERLIN_TUI") && !@joined && (@joined = true)
      s&.finished? && !s.reporting?
    end
    with_test_terminal(100, 30, timeout: 15) do
      inject_keys(:end, :up, :enter, :enter)
      app(backend, isolation_factory: ->(out:) { iso }, speaker_opts: { host: "127.0.0.1", port: speaker.port })
        .run(stop_when: stop)
    end
    assert_equal %i[authorize enable disable], iso.calls
    assert_equal :done, sync_screen.session.state
  ensure
    speaker&.stop
  end

  def test_traffic_filter_can_be_turned_off
    @config.setting_id = "s1"
    calls = []
    factory = ->(out:) { calls << :created && nil }
    with_test_terminal(100, 30) do
      # Sync now -> 3rd row (filter toggle) -> off; screen shows the warning
      inject_keys(:end, :up, :enter, :down, :down, :enter)
      app(FakeBackend.new, isolation_factory: factory)
        .run(stop_when: ->(a) { a.screen.is_a?(Merlin::TUI::Screens::SyncScreen) && screen_text.include?("off (speaker may crash)") })
    end
    assert_empty calls # nothing created until a transfer starts
  end

  def screen_text = buffer_content.join("\n")

  def test_login_auto_selects_single_speaker
    backend = FakeBackend.new(logged_in: false)
    with_test_terminal(100, 30) do
      inject_keys(:enter, *"kid@example.com".chars, :enter, *"pw".chars, :enter)
      app(backend).run(stop_when: ->(a) { a.screen.is_a?(Merlin::TUI::Screens::MainMenu) && backend.logged_in? })
      assert_includes screen_text, "Speaker: Chambre"
      assert_includes screen_text, "Logged in as kid@example.com"
    end
    assert_equal [:login, "kid@example.com", "pw"], backend.calls.first
    assert_equal "s1", @config.setting_id
  end

  def test_failed_login_shows_error
    backend = FakeBackend.new(logged_in: false)
    with_test_terminal(100, 30) do
      inject_keys(:enter, "a", :tab, *"bad".chars, :enter)
      app(backend).run(stop_when: ->(_) { backend.calls.any? })
      assert_includes screen_text, "authentication failed"
      assert_includes screen_text, "•••"
    end
  end

  def test_pick_speaker_among_several
    backend = FakeBackend.new
    backend.speakers_list << { "id" => "s2", "speaker_name" => "Salon" }
    with_test_terminal(100, 30) do
      # Menu: header, Speaker row is first selectable → enter, then pick 2nd
      inject_keys(:enter, :down, :enter)
      app(backend).run(stop_when: ->(_) { @config.setting_id == "s2" })
      assert_includes screen_text, "Speaker: Salon"
    end
  end

  def test_browse_collection_mark_and_add
    @config.setting_id = "s1"
    backend = FakeBackend.new
    with_test_terminal(100, 30) do
      # Menu → Browse (3 rows down from Speaker), → collection → mark ep1 and ep2 → a
      inject_keys(:down, :down, :down, :enter, :down, :enter, " ", " ", "a")
      app(backend).run(stop_when: ->(_) { backend.calls.any? { |c| c.first == :select } })
      assert_includes screen_text, "Odyssées"
    end
    assert_includes backend.calls, [:page, "home"]
    assert_includes backend.calls, [:collection, "c1"]
    assert_includes backend.calls, [:select, %w[k1 k2], true]
  end

  def test_add_whole_collection_from_page
    @config.setting_id = "s1"
    backend = FakeBackend.new
    with_test_terminal(100, 30) do
      inject_keys(:down, :down, :down, :enter, :down, "a")
      app(backend).run(stop_when: ->(_) { backend.calls.any? { |c| c.first == :select_collection } })
    end
    assert_includes backend.calls, [:select_collection, "c1"]
  end

  def test_library_queue_removal_then_cancel_in_basket
    @config.setting_id = "s1"
    backend = FakeBackend.new
    with_test_terminal(100, 30) do
      # Menu → On my speaker; mark "Le loup" (second leaf) → d; back; Basket → x
      inject_keys(:down, :down, :enter, :down, " ", "d", :esc, :down, :down, :down, :enter, "x")
      app(backend).run(stop_when: ->(_) { backend.calls.any? { |c| c.first == :cancel } })
    end
    assert_includes backend.calls, [:select, ["a2"], false]
    assert_includes backend.calls, [:cancel, ["a2"]]
  end

  def test_search
    @config.setting_id = "s1"
    backend = FakeBackend.new
    with_test_terminal(100, 30) do
      inject_keys(:down, :down, :down, :down, :enter, *"brun".chars, :enter)
      app(backend).run(stop_when: ->(a) { a.screen.is_a?(Merlin::TUI::Screens::ResultsScreen) })
      assert_includes screen_text, "Petit ours brun"
    end
  end

  class FakeSync
    def initialize(out:, wifi:, on_transfer_end: nil)
      @out = out
      @wifi = wifi
      @on_transfer_end = on_transfer_end
    end

    def run
      @out.puts "Synchro 42: 1 file(s) in plan"
      @wifi.join_speaker("MERLIN-1234", "secret")
      @out.print "\r  [audio 1/1] a.mp3 50%"
      @out.print "\r  [audio 1/1] a.mp3 uploaded\n"
      @out.puts "Transfer complete."
      @on_transfer_end&.call(status: "SUCCESS")
      @wifi.restore
    end
  end

  def test_sync_waits_for_wifi_confirmation
    @config.setting_id = "s1"
    backend = FakeBackend.new
    sync_screen = nil
    confirmed = false
    finished_frames = 0
    stop = lambda do |a|
      sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
      session = sync_screen&.session
      # Confirm only once the Wi-Fi banner has actually been painted.
      if session&.wifi&.waiting && !confirmed && screen_text.include?("MERLIN-1234")
        assert_includes screen_text, "password: secret"
        inject_keys(:enter)
        confirmed = true
      end
      # stop on the frame after completion so the final log is on screen
      finished_frames += 1 if session&.finished?
      finished_frames > 1
    end
    with_test_terminal(100, 30) do
      # Menu → Sync now (2nd to last) → Start transfer
      inject_keys(:end, :up, :enter, :enter)
      app(backend, sync_factory: ->(**kw) { FakeSync.new(**kw) }).run(stop_when: stop)
      app_text = screen_text
      assert_includes app_text, "a.mp3 uploaded"
      refute_includes app_text, "50%"
    end
    assert_equal :done, sync_screen.session.state
  end

  # Goes offline while "on the speaker", then the user leaves the sync screen
  # before reconnecting — this used to crash the TUI (Socket::ResolutionError).
  class OfflineSync
    def initialize(out:, wifi:, backend:, on_transfer_end: nil)
      @out = out
      @wifi = wifi
      @backend = backend
      @on_transfer_end = on_transfer_end
    end

    def run
      @wifi.join_speaker("MERLIN_DKCRG8", "pw")
      @backend.online = false
      @out.puts "  [audio 1/1] a.mp3 uploaded"
      @on_transfer_end&.call(status: "SUCCESS")
      @out.puts(@wifi.restore == :skip ? "Report saved for next sync." : "Report sent.")
    end
  end

  def test_back_to_menu_while_offline_does_not_crash
    @config.setting_id = "s1"
    backend = FakeBackend.new
    sync_screen = nil
    pressed = []
    stop = lambda do |a|
      sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
      wifi = sync_screen&.session&.wifi
      if wifi&.waiting && !pressed.include?(:join) && screen_text.include?("MERLIN_DKCRG8")
        inject_keys(:enter) && pressed << :join
      elsif wifi&.reconnecting && !pressed.include?(:skip) && screen_text.include?("Back to your usual Wi-Fi")
        inject_keys(:enter) && pressed << :skip # don't wait for internet
      elsif sync_screen&.session&.finished? && pressed.include?(:skip) && !pressed.include?(:esc)
        inject_keys(:esc) && pressed << :esc # back to the menu while still offline
      end
      a.screen.is_a?(Merlin::TUI::Screens::MainMenu) && pressed.include?(:esc)
    end
    with_test_terminal(100, 30) do
      inject_keys(:end, :up, :enter, :enter)
      app(backend, sync_factory: ->(**kw) { OfflineSync.new(**kw, backend: backend) })
        .run(stop_when: stop)
      assert_includes screen_text, "can't reach api.hello-merlin.com"
      assert_includes screen_text, "Sync now"
    end
    assert_equal %i[join skip esc], pressed
    sync_screen.session.join(2) # the report step runs on after the screen was left
    assert_includes sync_screen.session.log.lines, "Report saved for next sync."
  end

  # Real Merlin::Sync against the fake speaker: the "back to your usual Wi-Fi"
  # banner must only ever be painted once the transfer result is on screen.
  def test_reconnect_banner_only_after_transfer_finished
    speaker = FakeSpeaker.new
    @config.setting_id = "s1"
    backend = FakeBackend.new
    sync_screen = nil
    banner_frames = 0
    frames_after_report = 0
    violations = []
    stop = lambda do |a|
      sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
      session = sync_screen&.session
      text = screen_text
      if text.include?("Back to your usual Wi-Fi")
        banner_frames += 1
        unless session.finished? && !text.include?("Transfer — running") && text.include?("✔ Transfer complete") &&
               text.include?("Transfer — done · reporting to Merlin")
          violations << text
        end
        backend.online = true if banner_frames == 3 # the user is back on their usual Wi-Fi
      end
      if session&.wifi&.waiting && text.include?("MERLIN_TUI") && backend.online != false
        backend.online = false # the Mac is now on the speaker's access point
        inject_keys(:enter)
      end
      frames_after_report += 1 if session&.finished? && !session.reporting?
      frames_after_report > 1
    end
    with_test_terminal(100, 30, timeout: 15) do
      inject_keys(:end, :up, :enter, :enter)
      app(backend, speaker_opts: { host: "127.0.0.1", port: speaker.port }).run(stop_when: stop)
      refute_includes screen_text, "Back to your usual Wi-Fi", "banner must go away once online"
    end
    assert_empty violations, "reconnect banner shown while the sync was still underway:\n#{violations.first}"
    assert_operator banner_frames, :>=, 3
    assert_equal ["syn-tui", "SUCCESS"], [backend.reports.last[0], backend.reports.last[1][:status]]
    assert_includes sync_screen.session.log.lines, "Report sent to the Merlin backend."
    assert_equal ["i.jpg", "a.mp3", "playlist-syn-tui.json"].sort, speaker.files.keys.sort
  ensure
    speaker&.stop
  end

  def test_reconnect_banner_clears_by_itself_once_online
    online_after = Time.now + 0.5
    wifi = Merlin::TUI::TuiWifi.new(auto: false, log: Merlin::TUI::SyncLog.new, online: -> { Time.now > online_after })
    seen = nil
    t = Thread.new { wifi.restore }
    sleep 0.1
    seen = wifi.reconnecting
    assert_equal :online, t.value
    assert seen
    refute wifi.reconnecting
  end

  def test_sync_log_handles_carriage_returns
    log = Merlin::TUI::SyncLog.new
    log.puts "one"
    log.print "\rprog 10%", "\rprog 99%"
    log.print "\rprog done\n"
    log.puts
    assert_equal ["one", "prog done", ""], log.lines
  end
end
