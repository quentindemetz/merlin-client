# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/merlin"
require_relative "fake_speaker"

class ProtocolTest < Minitest::Test
  P = Merlin::Protocol

  def test_crc_matches_crc32_mpeg2_check_value
    assert_equal 0x0376E6E7, P.crc32_mpeg2("123456789")
  end

  def test_encode_layout
    frame = P.encode(P::Cmd::PING)
    assert_equal 6, frame.bytesize
    assert_equal 5, frame.getbyte(0)
    assert_equal 2, frame.getbyte(1)
    assert_equal P.crc32_mpeg2("\x02"), frame.byteslice(2, 4).unpack1("V")
  end

  def test_decoder_handles_split_garbage_and_bad_crc
    good = P.encode(5, "abc")
    bad = good.dup.tap { |f| f.setbyte(2, 0) }
    d = P::Decoder.new
    d << "\x01\x02" << bad << good.byteslice(0, 3)
    assert_nil d.next_frame
    d << good.byteslice(3..)
    frame = d.next_frame
    assert_equal [5, "abc"], [frame.cmd, frame.payload]
    assert_nil d.next_frame
  end
end

class SpeakerTest < Minitest::Test
  def setup
    @fake = FakeSpeaker.new
    @speaker = Merlin::Speaker.new(host: "127.0.0.1", port: @fake.port).connect
  end

  def teardown
    @speaker.close
    @fake.stop
  end

  def test_info
    info = @speaker.info
    assert_equal "1.4.27", info[:firmware_version]
    assert_equal "170:187:204:1:2:3", info[:mac_address]
    assert_equal({ level: 87, charging: true }, info[:battery])
    assert_equal 8_000_000, info[:total_size]
    assert_equal 1_000_000, info[:available_space]
    assert_nil info[:date]
    assert @speaker.ping
  end

  def test_upload_large_file_then_skip_identical
    data = Random.new(1).bytes(350_000)
    progress = []
    assert_equal :uploaded, @speaker.upload("a.mp3", data) { |sent, _| progress << sent }
    assert_equal data, @fake.files["a.mp3"]
    assert_equal [102_400, 204_800, 307_200, 350_000], progress
    assert_equal({ found: true, sha256: Digest::SHA256.hexdigest(data) }, @speaker.search_file("a.mp3"))
    assert_equal :already_present, @speaker.sync_file("a.mp3", data)
    assert_equal :already_present, @speaker.upload("a.mp3", data)
  end

  def test_search_missing
    assert_equal({ found: false, sha256: nil }, @speaker.search_file("nope.mp3"))
  end

  def test_get_file_reads_raw_stream
    @fake.files["x.bin"] = "hello world".b * 1000
    assert_equal "hello world".b * 1000, @speaker.get_file("x.bin")
    assert_equal "ping-after", @speaker.ping && "ping-after"
  end

  def test_playlist_update_errors_are_named
    @speaker.upload("playlist-1.json", "[]")
    assert @speaker.update_playlist("playlist-1.json")
    err = assert_raises(Merlin::SpeakerError) { @speaker.update_playlist("missing.json") }
    assert_match(/FILE_NOT_FOUND/, err.message)
  end

  def test_settings
    t = Time.new(2026, 10, 2, 19, 30, 0, "+02:00")
    @speaker.set_date(t)
    assert_equal Time.utc(2026, 10, 2, 19, 30, 0).to_i, @fake.date
    assert_equal Time.utc(2026, 10, 2, 19, 30, 0), @speaker.date
    @speaker.set_enabling_hours([[7, 0], [12, 30]], [[10, 0], [10, 0]])
    assert_equal [7, 0, 12, 30, 10, 0, 10, 0], @fake.hours
    @speaker.set_wifi("Home", "secret")
    assert_equal %w[Home secret], @fake.wifi
  end

  def test_unknown_command_raises
    assert_raises(Merlin::SpeakerError) { @speaker.request(99) }
  end
end
