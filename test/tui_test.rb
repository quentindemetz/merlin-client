# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ratatui_ruby"
require "ratatui_ruby/test_helper"
require_relative "../lib/merlin/tui"

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
    def selections = @basket

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
  end

  def setup
    @dir = Dir.mktmpdir
    @config = Merlin::Config.new(@dir)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def app(backend, **)
    Merlin::TUI::App.new(backend: backend, config: @config, **)
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
    def initialize(out:, wifi:)
      @out = out
      @wifi = wifi
    end

    def run
      @out.puts "Synchro 42: 1 file(s) in plan"
      @wifi.join_speaker("MERLIN-1234", "secret")
      @out.print "\r  [audio 1/1] a.mp3 50%"
      @out.print "\r  [audio 1/1] a.mp3 uploaded\n"
      @out.puts "Transfer complete."
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
      app(backend, sync_factory: ->(out:, wifi:) { FakeSync.new(out: out, wifi: wifi) }).run(stop_when: stop)
      app_text = screen_text
      assert_includes app_text, "a.mp3 uploaded"
      refute_includes app_text, "50%"
    end
    assert_equal :done, sync_screen.session.state
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
