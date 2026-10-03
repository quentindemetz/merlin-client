# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Real ffmpeg on tiny generated files.
class MediaTest < Minitest::Test
  M = Merlin::Media

  def setup
    skip "ffmpeg not installed" unless M.available?
    @dir = Dir.mktmpdir
  end

  def teardown = @dir && FileUtils.rm_rf(@dir)

  def gen(name, *args)
    path = File.join(@dir, name)
    M.ffmpeg!(*args, path)
    path
  end

  def test_speaker_ready_mp3_is_copied_and_its_artwork_used
    src = gen("song.mp3", "-f", "lavfi", "-i", "sine=d=1", "-f", "lavfi", "-i", "color=red:s=300x200",
              "-map", "0:a", "-map", "1:v", "-frames:v", "1", "-c:a", "libmp3lame", "-ar", "44100", "-ac", "2",
              "-b:a", "128k", "-c:v", "mjpeg", "-disposition:v", "attached_pic", "-id3v2_version", "3",
              "-metadata", "title=Bonne nuit")
    info = M.probe(src)
    assert_equal ["Bonne nuit", "mp3", 44_100, 2, true], [info.title, info.codec, info.sample_rate, info.channels, info.has_cover]

    out = File.join(@dir, "out.mp3")
    assert_equal :copied, M.prepare_audio(src, out, info)
    assert_equal File.binread(src), File.binread(out)

    cover = File.join(@dir, "cover.jpg")
    assert_equal :embedded, M.prepare_cover(src, cover, info)
    assert_jpeg_128(cover)
  end

  def test_other_formats_are_transcoded_to_the_speaker_format
    mono_wav = gen("talk.wav", "-f", "lavfi", "-i", "sine=d=1:sample_rate=22050", "-ac", "1")
    stereo_flac = gen("music.flac", "-f", "lavfi", "-i", "sine=d=1:sample_rate=48000", "-ac", "2")

    { mono_wav => [1, 64_000], stereo_flac => [2, 128_000] }.each do |src, (channels, bit_rate)|
      out = File.join(@dir, "#{File.basename(src)}.mp3")
      assert_equal :transcoded, M.prepare_audio(src, out)
      info = M.probe(out)
      assert_equal ["mp3", 44_100, channels], [info.codec, info.sample_rate, info.channels], src
      assert_in_delta bit_rate, info.bit_rate, 8_000
      assert M.speaker_ready?(info)
    end
  end

  def test_default_cover_when_there_is_no_artwork
    src = gen("plain.wav", "-f", "lavfi", "-i", "sine=d=1")
    cover = File.join(@dir, "c.jpg")
    assert_equal :default, M.prepare_cover(src, cover)
    assert_jpeg_128(cover)
  end

  def test_files_without_audio_are_rejected
    png = gen("pic.png", "-f", "lavfi", "-i", "color=blue:s=10x10", "-frames:v", "1")
    err = assert_raises(Merlin::Error) { M.probe(png) }
    assert_match(/has no audio/, err.message)
  end

  private

  def assert_jpeg_128(path)
    out, = Open3.capture2("ffprobe", "-v", "error", "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", path)
    assert_equal "mjpeg,128,128", out.strip
  end
end
