# frozen_string_literal: true

require "json"
require "uri"
require "date"
require "fileutils"
require "securerandom"
require "digest"
require "faraday"

module Merlin
  # Scrubs secrets and personal data from anything about to be logged.
  module Redact
    module_function

    REDACTED = "[REDACTED]"

    def norm(key) = key.to_s.downcase.delete("-_")

    # Credentials: never logged.
    SECRET_NAMES = %w[
      access_token refresh_token id_token token password pendingPassword client_secret
      authorization proxy-authorization cookie set-cookie
    ].freeze

    # Personal data: the account holder, their home network, names they chose,
    # device identifiers.
    PII_NAMES = %w[
      username email mail first_name last_name firstname lastname phone phone_number
      address street zipcode zip postal_code city birthdate birth_date birthday
      pendingSsid sta_ssid speaker_name child_name mac_address
    ].freeze

    SECRET_KEYS = SECRET_NAMES.map { norm(_1) }.freeze
    PII_KEYS = PII_NAMES.map { norm(_1) }.freeze

    # Same keys inside raw text (truncated / malformed JSON, form bodies), in
    # any of snake_case, camelCase or kebab-case.
    KEY_ALTS = (SECRET_NAMES + PII_NAMES).map { |n| n.split(/[-_]|(?=[A-Z])/).map { Regexp.escape(_1) }.join("[-_]?") }.join("|")
    JSON_PAIR = /("(?:#{KEY_ALTS})"\s*:\s*)("(?:[^"\\]|\\.)*"?|[^,}\]\s]+)/i
    FORM_PAIR = /(?<=\A|[&?\s])((?:#{KEY_ALTS})=)[^&\s]*/i

    SENSITIVE_PARAM = /token|sig|signature|secret|password|passwd|auth|credential|key|amz/i
    EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
    JWT = /\beyJ[\w-]{4,}\.[\w-]{4,}\.[\w-]*/
    BEARER = /\b(Bearer)\s+\S+/i

    def sensitive?(key) = SECRET_KEYS.include?(norm(key)) || PII_KEYS.include?(norm(key))

    # "ssid" is the speaker's own access point in synchro plans (MERLIN_…), but
    # the user's home network in sta_wifi.json / Wi-Fi settings.
    def home_ssid?(key, val) = norm(key) == "ssid" && val.is_a?(String) && !val.match?(/\AMERLIN/i)

    def value(obj)
      case obj
      when Hash
        obj.to_h { |k, v| [k, (sensitive?(k) || home_ssid?(k, v)) && !v.nil? ? REDACTED : value(v)] }
      when Array then obj.map { |v| value(v) }
      when String then scrub(obj)
      else obj
      end
    end

    def scrub(str)
      str.gsub(JSON_PAIR, "\\1\"#{REDACTED}\"").gsub(FORM_PAIR, "\\1#{REDACTED}")
         .gsub(BEARER, "\\1 #{REDACTED}").gsub(JWT, "[JWT]").gsub(EMAIL, "[EMAIL]")
    end

    def url(raw)
      uri = URI(raw.to_s)
      if uri.query
        uri.query = URI.decode_www_form(uri.query).map do |k, v|
          [k, sensitive?(k) || k.match?(SENSITIVE_PARAM) ? REDACTED : v]
        end.then { URI.encode_www_form(_1) }
      end
      scrub(uri.to_s)
    rescue URI::Error, ArgumentError
      scrub(raw.to_s)
    end

    def headers(hash)
      hash.to_h.to_h do |k, v|
        [k, if sensitive?(k) then REDACTED
            elsif k.to_s.casecmp?("location") then url(v)
            else scrub(v.to_s)
            end]
      end
    end

    # Parses JSON / form bodies so keys can be redacted; other text is scrubbed,
    # binary is summarised.
    def body(raw, content_type = nil)
      return nil if raw.nil? || raw.to_s.empty?

      raw = raw.to_s
      if content_type.to_s.include?("json") || raw.lstrip.start_with?("{", "[")
        value(JSON.parse(raw))
      elsif content_type.to_s.include?("x-www-form-urlencoded")
        value(URI.decode_www_form(raw).to_h)
      elsif raw.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !raw.include?("\0")
        scrub(raw.dup.force_encoding(Encoding::UTF_8))
      else
        "<binary #{raw.bytesize} bytes>"
      end
    rescue JSON::ParserError
      scrub(raw.dup.force_encoding(Encoding::UTF_8).scrub)
    end
  end

  # Append-only JSON-lines log of every HTTP exchange, one file per day,
  # readable only by the user. Thread-safe (the TUI syncs in a background thread).
  class HttpLog
    MAX_BODY = 1_000_000 # bytes of (already redacted) JSON per body

    attr_reader :dir

    def initialize(dir:, echo: nil, keep_days: 14)
      @dir = dir
      @echo = echo
      @mutex = Mutex.new
      FileUtils.mkdir_p(dir, mode: 0o700)
      prune(keep_days)
    end

    def path = File.join(dir, "http-#{Date.today.iso8601}.jsonl")

    def record(entry)
      line = JSON.generate(entry)
      @mutex.synchronize do
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |f| f.puts(line) }
      end
      @echo&.call(summary(entry))
    rescue SystemCallError, IOError, JSON::GeneratorError => e
      @echo&.call("http log write failed: #{e.message}")
    end

    # Middleware: install with `f.use Merlin::HttpLog::Middleware, http_log`.
    class Middleware < Faraday::Middleware
      def initialize(app, log)
        super(app)
        @log = log
      end

      def call(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        entry = {
          id: SecureRandom.hex(4),
          at: Time.now.utc.iso8601(3),
          request: {
            method: env.method.to_s.upcase,
            url: Redact.url(env.url),
            headers: Redact.headers(env.request_headers),
            body: HttpLog.cap(Redact.body(env.request_body, env.request_headers["Content-Type"]))
          }.compact
        }
        capture = StreamCapture.wrap(env)

        @app.call(env).on_complete do |res|
          content_type = res.response_headers&.[]("content-type")
          entry[:duration_ms] = elapsed_ms(started)
          entry[:response] = {
            status: res.status,
            headers: Redact.headers(res.response_headers),
            body: capture ? capture.body(content_type) : HttpLog.cap(Redact.body(res.response_body, content_type)),
            streamed_bytes: capture&.bytes
          }.compact
          @log.record(entry)
        end
      rescue Faraday::Error => e
        @log.record(entry.merge(duration_ms: elapsed_ms(started), error: "#{e.class}: #{Redact.scrub(e.message)}"))
        raise
      end

      private

      def elapsed_ms(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    # Streamed (on_data) responses never reach env.response_body, so tee the
    # chunks: keep the first TEXT_LIMIT bytes for logging and hash the rest.
    class StreamCapture
      TEXT_LIMIT = 256 * 1024

      attr_reader :bytes

      def self.wrap(env)
        original = env.request.on_data
        return nil unless original

        capture = new
        env.request.on_data = proc do |chunk, size, e|
          capture << chunk
          original.call(chunk, size, e)
        end
        capture
      end

      def initialize
        @bytes = 0
        @head = +"".b
        @sha = Digest::SHA256.new
      end

      def <<(chunk)
        @bytes += chunk.bytesize
        @sha << chunk
        @head << chunk.byteslice(0, TEXT_LIMIT - @head.bytesize) if @head.bytesize < TEXT_LIMIT
      end

      # Text/JSON bodies (error pages, sta_wifi.json…) are logged redacted;
      # binary payloads (MP3/JPG) as a summary that can be checked against the
      # speaker's SHA-256.
      def body(content_type)
        return nil if @bytes.zero?

        if textual?(content_type)
          text = Redact.body(@head, content_type)
          @bytes > TEXT_LIMIT ? { _truncated: true, bytes: @bytes, head: JSON.generate(text) } : HttpLog.cap(text)
        else
          "<binary #{@bytes} bytes, #{content_type || 'unknown type'}, sha256=#{@sha.hexdigest}>"
        end
      end

      private

      def textual?(content_type)
        return content_type.match?(%r{\A(text/|application/(json|xml|problem|x-www-form-urlencoded|javascript))|\+json|\+xml}i) if content_type

        sample = @head.byteslice(0, 1024).dup.force_encoding(Encoding::UTF_8)
        sample.valid_encoding? && !sample.include?("\0")
      end
    end

    def self.cap(body)
      return body if body.nil?

      json = JSON.generate(body)
      return body if json.bytesize <= MAX_BODY

      { _truncated: true, bytes: json.bytesize, head: json.byteslice(0, MAX_BODY).scrub }
    end

    private

    def summary(e)
      req = e[:request]
      outcome = e[:error] || "#{e.dig(:response, :status)}#{" (#{e.dig(:response, :streamed_bytes)} B)" if e.dig(:response, :streamed_bytes)}"
      "#{req[:method]} #{req[:url]} -> #{outcome} [#{e[:duration_ms]}ms]"
    end

    def prune(keep_days)
      cutoff = Date.today - keep_days
      Dir.glob(File.join(dir, "http-*.jsonl")).each do |f|
        date = Date.iso8601(File.basename(f)[/\d{4}-\d{2}-\d{2}/]) rescue next
        File.delete(f) if date < cutoff
      end
    end
  end
end
