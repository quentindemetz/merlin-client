# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/merlin"
require_relative "fake_speaker"

class SyncTest < Minitest::Test
  # Simulated network: while the laptop is on the speaker's access point the
  # Merlin API is unreachable, and any attempt to use it is recorded.
  class SimNet
    attr_accessor :on_speaker, :user_reconnects
    attr_reader :offline_calls

    def initialize
      @on_speaker = false
      @user_reconnects = true
      @offline_calls = []
    end
  end

  class StubBackend
    attr_reader :reports, :downloads
    attr_accessor :fail_reports

    def initialize(plan, contents, net)
      @plan = plan
      @contents = contents
      @net = net
      @reports = []
      @downloads = []
    end

    def reachable? = !@net.on_speaker

    def create_synchro(type:)
      guard!(:create_synchro)
      @plan.merge("type" => type)
    end

    def download(url, dest)
      guard!(:download)
      @downloads << url
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, @contents.fetch(url))
    end

    def report_synchro(id, body)
      guard!(:report_synchro)
      raise Merlin::BackendError, "server error" if fail_reports

      @reports << [id, body]
    end

    private

    def guard!(call)
      return unless @net.on_speaker

      @net.offline_calls << call
      raise Merlin::OfflineError, "can't reach api.hello-merlin.com"
    end
  end

  class NoWifi
    def initialize(net) = @net = net
    def join_speaker(*) = @net.on_speaker = true
    def restore = @net.on_speaker = !@net.user_reconnects
  end

  PLAYLIST = '[{"uuid":"u1","title":"Contes","child":[{"uuid":"a1","title":"Le loup"}]}]'

  def setup
    @fake = FakeSpeaker.new
    @dir = Dir.mktmpdir
    @audio = Random.new(2).bytes(250_000)
    @plan = {
      "id" => "syn-42",
      "fileList" => [
        { "type" => "audio", "url" => "https://cdn/a1.mp3", "filename" => "a1.mp3", "title" => "Le loup", "filesize" => @audio.bytesize },
        { "type" => "image", "url" => "https://cdn/u1.jpg", "filename" => "u1.jpg", "title" => "Contes" }
      ],
      "playlistText" => PLAYLIST,
      "time_slot" => { "weekDayActive" => true, "weekDayStart" => "07:30", "weekDayStop" => "19:45",
                       "weekEndActive" => false, "weekEndStart" => "08:00", "weekEndStop" => "20:00" },
      "pendingSsid" => "Home", "pendingPassword" => "pw"
    }
    @net = SimNet.new
    @backend = StubBackend.new(@plan, { "https://cdn/a1.mp3" => @audio, "https://cdn/u1.jpg" => "JPEGDATA" }, @net)
  end

  def teardown
    @fake.stop
    FileUtils.rm_rf(@dir)
  end

  def run_sync(out = StringIO.new)
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: out).run
  end

  def test_full_sync
    run_sync

    assert_equal @audio, @fake.files["a1.mp3"]
    assert_equal "JPEGDATA", @fake.files["u1.jpg"]
    assert_equal PLAYLIST, @fake.files["playlist-syn-42.json"]
    assert_equal ["playlist-syn-42.json"], @fake.playlist_updates
    assert_equal [7, 30, 19, 45, 10, 0, 10, 0], @fake.hours
    assert_equal %w[Home pw], @fake.wifi
    refute_nil @fake.date
    assert_includes @fake.commands, Merlin::Protocol::Cmd::END_SYNCHRONIZATION
    # images are pushed before audio
    uploads = @fake.commands.each_index.select { |i| @fake.commands[i] == Merlin::Protocol::Cmd::UPLOAD_FILE }
    assert_operator uploads.size, :>=, 3

    id, body = @backend.reports.last
    assert_equal "syn-42", id
    assert_equal "SUCCESS", body[:status]
    assert_equal "100_SUCCEED", body[:status_code]
    assert_equal "TRANSFERT", body[:type]
    assert_equal "1.4.27", body[:firmware_version]
    assert_equal 8_000_000, body[:sd_size]
  end

  def test_no_api_call_while_on_speaker_wifi
    run_sync
    assert_empty @net.offline_calls, "Merlin API was called while on the speaker's Wi-Fi"
    assert_equal "SUCCESS", @backend.reports.last[1][:status]
  end

  def test_user_never_reconnects_report_is_kept_for_later
    @net.user_reconnects = false
    out = StringIO.new
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net), internet_wait: 0,
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: out).run
    assert_empty @net.offline_calls, "no API attempt should be made while still offline"
    assert_empty @backend.reports
    assert_match(/will be sent at the next sync/, out.string)
    pending = JSON.parse(File.read(File.join(@dir, "pending_report.json")))
    assert_equal %w[syn-42 SUCCESS], [pending["id"], pending.dig("body", "status")]

    # Back home; next sync (where the user does reconnect) delivers it first.
    @net.on_speaker = false
    @net.user_reconnects = true
    run_sync
    assert_equal %w[SUCCESS SUCCESS], @backend.reports.map { |_, b| b[:status] || b["status"] }
    refute File.exist?(File.join(@dir, "pending_report.json"))
  end

  def test_second_sync_skips_downloads_and_uploads
    run_sync
    out = StringIO.new
    run_sync(out)
    assert_equal 2, @backend.downloads.size
    assert_match(/0 file\(s\) uploaded, 2 already on the speaker/, out.string)
  end

  def test_download_failure_is_reported
    def @backend.download(*) = raise(URI::InvalidURIError, "bad URI")
    err = assert_raises(Merlin::Sync::Failure) { run_sync }
    assert_equal "202_FAILED_ON_PREPARE_CONTENT_FILES", err.code
    assert_equal ["syn-42", "FAIL", "202_FAILED_ON_PREPARE_CONTENT_FILES"],
                 [@backend.reports.last[0], *@backend.reports.last[1].values_at(:status, :status_code)]
  end

  def test_playlist_failure_is_reported
    @plan["playlistText"] = nil
    assert_raises(Merlin::Sync::Failure) { run_sync }
    assert_equal "203_FAILED_ON_PREPARE_CONTENT_PLAYLIST", @backend.reports.last[1][:status_code]
  end

  def test_unreachable_speaker_reports_failure_and_saves_pending_report
    @fake.stop
    @backend.fail_reports = true
    sync = Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                            speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: StringIO.new)
    sync.define_singleton_method(:connect_with_retry) do |*, **|
      raise Merlin::Sync::Failure.new("510_FAILED_ON_SDK_ESTABLISH_CONNEXION", "unreachable")
    end
    sync.define_singleton_method(:sleep) { |*| nil }
    err = assert_raises(Merlin::Sync::Failure) { sync.run }
    assert_equal "510_FAILED_ON_SDK_ESTABLISH_CONNEXION", err.code
    pending = JSON.parse(File.read(File.join(@dir, "pending_report.json")))
    assert_equal "FAIL", pending["body"]["status"]

    @backend.fail_reports = false
    @fake = FakeSpeaker.new
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: StringIO.new).run
    assert_equal ["syn-42", "syn-42"], @backend.reports.map(&:first)
    assert_equal "510_FAILED_ON_SDK_ESTABLISH_CONNEXION", @backend.reports.first[1][:status_code]
    refute File.exist?(File.join(@dir, "pending_report.json"))
  end
end
