# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/merlin"
require_relative "fake_speaker"

class SyncTest < Minitest::Test
  class StubBackend
    attr_reader :reports, :downloads
    attr_accessor :fail_reports

    def initialize(plan, contents)
      @plan = plan
      @contents = contents
      @reports = []
      @downloads = []
    end

    def create_synchro(type:) = @plan.merge("type" => type)

    def download(url, dest)
      @downloads << url
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, @contents.fetch(url))
    end

    def report_synchro(id, body)
      raise Merlin::BackendError, "offline" if fail_reports

      @reports << [id, body]
    end
  end

  class NoWifi
    def join_speaker(*) = nil
    def restore = nil
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
    @backend = StubBackend.new(@plan, "https://cdn/a1.mp3" => @audio, "https://cdn/u1.jpg" => "JPEGDATA")
  end

  def teardown
    @fake.stop
    FileUtils.rm_rf(@dir)
  end

  def run_sync(out = StringIO.new)
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new,
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

  def test_second_sync_skips_downloads_and_uploads
    run_sync
    out = StringIO.new
    run_sync(out)
    assert_equal 2, @backend.downloads.size
    assert_match(/0 file\(s\) uploaded, 2 already on the speaker/, out.string)
  end

  def test_playlist_failure_is_reported
    @plan["playlistText"] = nil
    assert_raises(Merlin::Sync::Failure) { run_sync }
  end

  def test_unreachable_speaker_reports_failure_and_saves_pending_report
    @fake.stop
    @backend.fail_reports = true
    sync = Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new,
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
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new,
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: StringIO.new).run
    assert_equal ["syn-42", "syn-42"], @backend.reports.map(&:first)
    assert_equal "510_FAILED_ON_SDK_ESTABLISH_CONNEXION", @backend.reports.first[1][:status_code]
    refute File.exist?(File.join(@dir, "pending_report.json"))
  end
end
