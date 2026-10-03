# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "ratatui_ruby"
require "ratatui_ruby/test_helper"
require_relative "../lib/merlin/tui"
require_relative "fake_speaker"

require_relative "fake_network"

# The headless test terminal returns from poll_event immediately, so the UI
# loop would spin flat out and starve background sync threads: throttle it.
Merlin::TUI::App.prepend(Module.new do
  def run(stop_when: nil, **opts)
    throttled = stop_when && lambda do |app|
      sleep 0.002
      stop_when.call(app)
    end
    super(stop_when: throttled, **opts)
  end
end)

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
  def app(backend, isolation_factory: ->(out:) { nil }, network: FakeNetwork.new(speaker: "MERLIN_TUI"), **)
    Merlin::TUI::App.new(backend: backend, config: @config, isolation_factory: isolation_factory, network: network, **)
  end

  class RecordingIsolation
    attr_reader :calls

    attr_writer :out

    def initialize = @calls = []
    def authorize! = (@calls << :authorize) && (@authorized = true)
    def authorized? = @authorized
    def enable! = @calls << :enable
    def disable! = @calls << :disable
    def active? = @calls.last == :enable
    def shutdown_helper = (@calls << :shutdown) && (@authorized = false)
  end

  # A sync that finishes at once (no Wi-Fi step), to run several in a row.
  class QuickSync
    def initialize(out:, on_transfer_end: nil, **) = (@out = out) && (@done = on_transfer_end)

    def run
      @out.puts "Transfer complete."
      @done&.call(status: "SUCCESS")
    end
  end

  def test_admin_password_asked_once_at_startup_for_the_whole_session
    iso = RecordingIsolation.new
    with_test_terminal(100, 30) do
      capture_io do
        app(FakeBackend.new, isolation_factory: ->(out:) { iso }).run(preauthorize: true, stop_when: ->(_) { true })
      end
    end
    assert_equal %i[authorize shutdown], iso.calls # helper stops when the program does
  end

  def test_several_syncs_reuse_the_same_authorization
    @config.setting_id = "s1"
    iso = RecordingIsolation.new
    sessions = []
    stop = lambda do |a|
      s = a.screen.is_a?(Merlin::TUI::Screens::SyncScreen) && a.screen.session
      if s && s.finished? && !s.reporting? && !sessions.include?(s)
        sessions << s
        inject_keys(:esc, :end, :up, :enter, :enter) if sessions.size == 1 # back to menu, sync again
      end
      sessions.size == 2
    end
    with_test_terminal(100, 30) do
      inject_keys(:end, :up, :enter, :enter)
      app(FakeBackend.new, isolation_factory: ->(out:) { iso }, sync_factory: ->(**kw) { QuickSync.new(**kw) })
        .run(stop_when: stop)
    end
    assert_equal 2, sessions.size
    assert_equal %i[authorize shutdown], iso.calls # one prompt for both syncs
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
      s&.finished? && !s.reporting? # the Mac joins the speaker by itself
    end
    with_test_terminal(100, 30, timeout: 15) do
      inject_keys(:end, :up, :enter, :enter)
      app(backend, isolation_factory: ->(out:) { iso }, speaker_opts: { host: "127.0.0.1", port: speaker.port })
        .run(stop_when: stop)
    end
    assert_equal %i[authorize enable disable shutdown], iso.calls
    assert_equal :done, sync_screen.session.state
  ensure
    speaker&.stop
  end

  # Real ffmpeg on a tiny WAV: My audio files -> import -> new folder -> done.
  def test_import_audio_into_a_new_folder
    skip "ffmpeg not installed" unless Merlin::Media.available?
    @config.setting_id = "s1"
    wav = File.join(@dir, "berceuse.wav")
    Merlin::Media.ffmpeg!("-f", "lavfi", "-i", "sine=d=1:sample_rate=22050", "-ac", "1", wav)
    with_test_terminal(100, 30, timeout: 15) do
      # Menu: End=Quit, Up=Sync now, Up=My audio files
      inject_keys(:end, :up, :up, :enter, "i", *wav.chars, :enter, # path -> destination screen
                  :enter, *"Mes histoires".chars, :enter)            # "New folder in Contes…" -> name it
      app(FakeBackend.new).run(stop_when: lambda { |a|
        a.screen.is_a?(Merlin::TUI::Screens::LocalLibraryScreen) && screen_text.include?("berceuse")
      })
      assert_includes screen_text, "Mes histoires  (your folder)"
      assert_includes screen_text, "1 file(s) imported (1 transcoded)"
    end
    lib = @config.library
    folder = lib.folders.first
    assert_equal ["Mes histoires", "f"], [folder.title, folder.parent] # inside the speaker's "Contes" section
    track = lib.tracks.first
    assert_equal ["berceuse", folder.uuid], [track.title, track.parent]
    info = Merlin::Media.probe(lib.audio_path(track.uuid))
    assert_equal ["mp3", 44_100, 1], [info.codec, info.sample_rate, info.channels]
  end

  def test_import_rejects_paths_without_audio
    @config.setting_id = "s1"
    with_test_terminal(100, 30) do
      inject_keys(:end, :up, :up, :enter, "i", *File.join(@dir, "nothing-here.mp3").chars, :enter)
      app(FakeBackend.new).run(stop_when: ->(_) { screen_text.include?("no such file") })
    end
    assert @config.library.empty?
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
    @wifi.remember_home!
    @out.puts "Synchro 42: 1 file(s) in plan"
    @wifi.join_speaker("MERLIN-1234", "secret")
    @out.print "\r  [audio 1/1] a.mp3 50%"
    @out.print "\r  [audio 1/1] a.mp3 uploaded\n"
    @out.puts "Transfer complete."
    @on_transfer_end&.call(status: "SUCCESS")
    @wifi.restore
  end
end

# Full screen while the speaker's Wi-Fi is off; the Mac joins it by itself
# once it appears, then goes back to the network it was on.
def test_full_screen_prompt_until_the_speaker_appears
  @config.setting_id = "s1"
  net = FakeNetwork.new(speaker: "MERLIN-1234", speaker_appears_after: 10**9)
  sync_screen = nil
  prompt = nil
  finished_frames = 0
  stop = lambda do |a|
    sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
    session = sync_screen&.session
    if session&.wifi&.waiting && prompt.nil? && screen_text.include?("Looking for MERLIN-1234")
      prompt = screen_text
      net.speaker_appears_after = 0 # the user pressed the Wifi / Transfert button
    end
    finished_frames += 1 if session&.finished?
    finished_frames > 1
  end
  with_test_terminal(100, 30) do
    inject_keys(:end, :up, :enter, :enter) # Menu → Sync now → Start transfer
    app(FakeBackend.new, network: net, sync_factory: ->(**kw) { FakeSync.new(**kw) }).run(stop_when: stop)
    assert_includes screen_text, "a.mp3 uploaded"
  end
  assert_includes prompt, "Switch on the speaker's Wi-Fi"
  assert_includes prompt, "2. Press its Wifi / Transfert button"
  assert_includes prompt, "reconnects to Cohen when the transfer is over"
  refute_includes prompt, "Transfer —", "the prompt takes the whole screen"
  assert_equal [[:join, "MERLIN-1234", "secret"], [:forget, "MERLIN-1234"], [:join, "Cohen", nil]], net.calls
  assert_equal "Cohen", net.ssid
  assert_equal :done, sync_screen.session.state
end

# Goes offline while "on the speaker", then the user leaves the sync screen
# before internet is back — this used to crash the TUI (Socket::ResolutionError).
class OfflineSync
  def initialize(out:, wifi:, backend:, on_transfer_end: nil)
    @out = out
    @wifi = wifi
    @backend = backend
    @on_transfer_end = on_transfer_end
  end

  def run
    @wifi.join_speaker("MERLIN_TUI", "pw")
    @backend.online = false
    @out.puts "  [audio 1/1] a.mp3 uploaded"
    @on_transfer_end&.call(status: "SUCCESS")
    @wifi.restore # back on Cohen, but (in this test) no internet yet
    @out.puts "Report saved for next sync."
  end
end

def test_back_to_menu_while_offline_does_not_crash
  @config.setting_id = "s1"
  backend = FakeBackend.new
  sync_screen = nil
  left = false
  stop = lambda do |a|
    sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
    if sync_screen&.session&.finished? && !sync_screen.session.reporting? && !left
      inject_keys(:esc) # back to the menu while still offline
      left = true
    end
    a.screen.is_a?(Merlin::TUI::Screens::MainMenu) && left
  end
  with_test_terminal(100, 30) do
    inject_keys(:end, :up, :enter, :enter)
    app(backend, sync_factory: ->(**kw) { OfflineSync.new(**kw, backend: backend) }).run(stop_when: stop)
    assert_includes screen_text, "can't reach api.hello-merlin.com"
    assert_includes screen_text, "Sync now"
  end
  assert_includes sync_screen.session.log.lines, "Report saved for next sync."
end

# Real Merlin::Sync + fake speaker + fake Wi-Fi: remember the network after
# talking to Merlin, join the speaker by itself, come back, report.
def test_automatic_wifi_round_trip_with_the_real_sync
  speaker = FakeSpeaker.new
  @config.setting_id = "s1"
  backend = FakeBackend.new
  net = FakeNetwork.new(speaker: "MERLIN_TUI", speaker_appears_after: 2)
  net.on_join = ->(ssid) { backend.online = !ssid.start_with?("MERLIN") } # no internet on the speaker's AP
  sync_screen = nil
  stop = lambda do |a|
    sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
    s = sync_screen&.session
    s&.finished? && !s.reporting?
  end
  with_test_terminal(100, 30, timeout: 15) do
    inject_keys(:end, :up, :enter, :enter)
    app(backend, network: net, speaker_opts: { host: "127.0.0.1", port: speaker.port }).run(stop_when: stop)
  end
  log = sync_screen.session.log.lines
  assert_includes log, "Will reconnect to \"Cohen\" after the transfer."
  assert_includes log, "Joined the speaker's Wi-Fi MERLIN_TUI."
  assert_includes log, "Reconnecting to \"Cohen\"…"
  assert_includes log, "Report sent to the Merlin backend."
  assert_equal [[:join, "MERLIN_TUI", "pw"], [:forget, "MERLIN_TUI"], [:join, "Cohen", nil]], net.calls
  assert_equal ["syn-tui", "SUCCESS"], [backend.reports.last[0], backend.reports.last[1][:status]]
  assert_equal ["i.jpg", "a.mp3", "playlist-syn-tui.json"].sort, speaker.files.keys.sort
ensure
  speaker&.stop
end

# A failed transfer goes back to the remembered network too.
def test_reconnects_home_after_a_failed_transfer
  @config.setting_id = "s1"
  net = FakeNetwork.new(speaker: "MERLIN-1234")
  failing = Class.new(FakeSync) do
    def run
      @wifi.remember_home!
      @wifi.join_speaker("MERLIN-1234", "secret")
      @on_transfer_end&.call(status: "FAIL", status_code: "502_FAILED_ON_SDK_UPLOAD_FILE")
      @wifi.restore
      raise Merlin::Error, "speaker refused"
    end
  end
  sync_screen = nil
  with_test_terminal(100, 30) do
    inject_keys(:end, :up, :enter, :enter)
    app(FakeBackend.new, network: net, sync_factory: ->(**kw) { failing.new(**kw) }).run(stop_when: lambda { |a|
      sync_screen = a.screen if a.screen.is_a?(Merlin::TUI::Screens::SyncScreen)
      sync_screen&.session&.finished? && !sync_screen.session.reporting?
    })
  end
  assert_equal :failed, sync_screen.session.state
  assert_equal [:join, "Cohen", nil], net.calls.last
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
