# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/merlin"

class RedactTest < Minitest::Test
  R = Merlin::Redact

  def test_nested_keys_in_any_case_style
    body = { "access_token" => "a", "refreshToken" => "b", "user" => { "e-mail" => "x", "Email" => "y",
                                                                       "firstName" => "Q", "items" => [{ "password" => "p" }] },
             "title" => "Le loup", "pendingSsid" => nil }
    assert_equal({ "access_token" => "[REDACTED]", "refreshToken" => "[REDACTED]",
                   "user" => { "e-mail" => "[REDACTED]", "Email" => "[REDACTED]", "firstName" => "[REDACTED]",
                               "items" => [{ "password" => "[REDACTED]" }] },
                   "title" => "Le loup", "pendingSsid" => nil }, R.value(body))
  end

  def test_home_ssid_redacted_but_speaker_ap_kept
    assert_equal [{ "ssid" => "[REDACTED]", "password" => "[REDACTED]" }, { "ssid" => "MERLIN_DKCRG8" }],
                 R.value([{ "ssid" => "Freebox-1234", "password" => "pw" }, { "ssid" => "MERLIN_DKCRG8" }])
  end

  def test_free_text_scrubbing
    assert_equal "user [EMAIL] got Bearer [REDACTED] and [JWT]",
                 R.scrub("user kid@example.com got Bearer abc.def and eyJhbGciOiJ.eyJzdWIiOiIx.c2lnbmF0dXJl")
  end

  def test_truncated_json_still_redacts_known_keys
    truncated = '{"id":"s1","password":"ap-pass-777","pendingSsid":"Home","access_token":"tok'
    out = R.body(truncated, "application/json")
    refute_includes out, "ap-pass-777"
    refute_includes out, "Home\""
    refute_includes out, ':"tok' # the value, not the "access_token" key name
    assert_includes out, '"id":"s1"'
  end

  def test_form_and_url
    assert_equal({ "grant_type" => "refresh_token", "refresh_token" => "[REDACTED]", "client_id" => "app" },
                 R.body("grant_type=refresh_token&refresh_token=xyz&client_id=app", "application/x-www-form-urlencoded"))
    assert_equal "https://cdn/x.mp3?X-Amz-Signature=%5BREDACTED%5D&w=1", R.url("https://cdn/x.mp3?X-Amz-Signature=abc&w=1")
    assert_equal "https://h/u/[EMAIL]/x", R.url("https://h/u/kid@example.com/x")
  end

  def test_binary_and_headers
    assert_equal "<binary 4 bytes>", R.body("\xFF\xD8\x00\x01".b)
    assert_equal({ "Authorization" => "[REDACTED]", "Set-Cookie" => "[REDACTED]", "Location" => "https://x/?token=[REDACTED]",
                   "Content-Type" => "application/json" },
                 R.headers("Authorization" => "Bearer t", "Set-Cookie" => "s=1", "Location" => "https://x/?token=t",
                           "Content-Type" => "application/json"))
  end
end

class StreamCaptureTest < Minitest::Test
  def test_binary_summary_with_sha
    c = Merlin::HttpLog::StreamCapture.new
    data = Random.new(1).bytes(300_000)
    data.bytes.each_slice(65_536) { c << _1.pack("C*") }
    assert_equal "<binary 300000 bytes, audio/mpeg, sha256=#{Digest::SHA256.hexdigest(data)}>", c.body("audio/mpeg")
  end

  def test_text_error_page_is_logged_redacted
    c = Merlin::HttpLog::StreamCapture.new
    c << '{"error":"expired","token":"t0k"}'
    assert_equal({ "error" => "expired", "token" => "[REDACTED]" }, c.body("application/json"))
  end
end

class HttpLogFileTest < Minitest::Test
  def test_prunes_old_files_and_caps_bodies
    Dir.mktmpdir do |dir|
      old = File.join(dir, "http-#{(Date.today - 30).iso8601}.jsonl")
      recent = File.join(dir, "http-#{(Date.today - 2).iso8601}.jsonl")
      [old, recent].each { File.write(_1, "{}\n") }
      Merlin::HttpLog.new(dir: dir)
      refute File.exist?(old)
      assert File.exist?(recent)
    end
    big = { "x" => "a" * (Merlin::HttpLog::MAX_BODY + 10) }
    capped = Merlin::HttpLog.cap(big)
    assert capped[:_truncated]
    assert_operator capped[:head].bytesize, :<=, Merlin::HttpLog::MAX_BODY
  end
end
