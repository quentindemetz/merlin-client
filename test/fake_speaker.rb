# frozen_string_literal: true

require "socket"
require "digest"
require_relative "../lib/merlin/protocol"

# Minimal in-process emulation of the speaker firmware, built from the
# decompiled app's expectations. Used by the tests only.
class FakeSpeaker
  include Merlin::Protocol

  attr_reader :port, :files, :commands, :playlist_updates, :date, :hours, :wifi, :connections

  # Fault injection:
  #   silent_uploads: upload-header numbers (1-based, across connections) the
  #                   speaker never answers — what Verte did at image 36.
  #   upload_refusal: status code returned to every upload header instead of 0.
  #   silent_pings:   ping numbers (1-based) left unanswered, like a speaker that
  #                   accepts TCP right after rebooting but is not ready yet.
  #   reset_after_drop: after a silent upload, this many new connections are
  #                   accepted then reset at once (TCP RST), as Verte did while
  #                   its transfer service restarted.
  attr_accessor :silent_uploads, :upload_refusal, :silent_pings, :reset_after_drop
  #   legacy_search_layout: search reply without the size field (what the
  #                   app 1.20.5 code expects) instead of the real firmware's.
  attr_accessor :legacy_search_layout
  #   verify_rate:    bytes/s at which a verifying search hashes the file
  #                   (Verte: ~1.6 MB/s, so big MP3s take seconds).
  attr_accessor :verify_rate

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @files = {}
    @commands = []
    @playlist_updates = []
    @connections = 0
    @upload_headers = 0
    @silent_uploads = []
    @silent_pings = []
    @pings = 0
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def stop
    @server.close
    @thread.kill
  end

  private

  def serve
    loop do
      client = @server.accept
      @connections += 1
      if @resets_pending.to_i.positive?
        @resets_pending -= 1
        client.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii")) # close => RST
        client.close
        next
      end
      handle(client)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(sock)
    decoder = Decoder.new
    pending_upload = nil
    loop do
      data = sock.readpartial(65_536)
      decoder << data
      loop do
        if pending_upload
          pending_upload[:data] << decoder.take(pending_upload[:size] - pending_upload[:data].bytesize)
          break unless pending_upload[:data].bytesize == pending_upload[:size]

          ok = Digest::SHA256.digest(pending_upload[:data]) == pending_upload[:sha]
          @files[pending_upload[:name]] = pending_upload[:data] if ok
          reply(sock, Cmd::UPLOAD_FILE, [ok ? 1 : 4].pack("C"))
          pending_upload = nil
          next
        end
        frame = decoder.next_frame or break
        @commands << frame.cmd
        pending_upload = dispatch(sock, frame)
      end
    end
  rescue EOFError, IOError, SystemCallError # client gone (e.g. it timed out and hung up)
    sock.close
  end

  def dispatch(sock, frame)
    p = frame.payload
    case frame.cmd
    when Cmd::PING
      @pings += 1
      reply(sock, frame.cmd, "") unless @silent_pings.include?(@pings)
    when Cmd::END_SYNCHRONIZATION, Cmd::RESET
      reply(sock, frame.cmd, "")
    when Cmd::AVAILABLE_SPACE then reply(sock, frame.cmd, [1_000_000].pack("V"))
    when Cmd::TOTAL_SIZE then reply(sock, frame.cmd, [8_000_000].pack("V"))
    when Cmd::FIRMWARE_VERSION then reply(sock, frame.cmd, [1, 4].pack("C2") + [27].pack("v"))
    when Cmd::BATTERY_STATE then reply(sock, frame.cmd, [87, 1].pack("C2"))
    when Cmd::MAC_ADDRESS then reply(sock, frame.cmd, [0xAA, 0xBB, 0xCC, 1, 2, 3].pack("C6"))
    when Cmd::GET_DATE then reply(sock, frame.cmd, [@date || 0].pack("V"))
    when Cmd::SET_DATE
      @date = p.unpack1("V")
      reply(sock, frame.cmd, "\x00")
    when Cmd::SET_ENABLING_HOURS
      @hours = p.bytes
      reply(sock, frame.cmd, "\x00")
    when Cmd::SET_WIFI
      ssid_len = p.getbyte(1)
      @wifi = [p.byteslice(3, ssid_len), p.byteslice(3 + ssid_len, p.getbyte(2))]
      reply(sock, frame.cmd, "\x00")
    when Cmd::UPDATE_PLAYLIST
      @playlist_updates << p
      reply(sock, frame.cmd, [@files.key?(p) ? 0 : 3].pack("C"))
    when Cmd::SEARCH_FILE
      name = p.byteslice(1..)
      if @files.key?(name)
        # Like the real speaker, verifying means reading + hashing the file.
        sleep(@files[name].bytesize.to_f / verify_rate) if verify_rate && p.getbyte(0) == 1
        # Real firmware 2.1.16 layout (captured from Verte): size before the hash.
        size = legacy_search_layout ? "".b : [@files[name].bytesize].pack("V")
        reply(sock, frame.cmd, [0, name.bytesize].pack("C2") + name + size + Digest::SHA256.digest(@files[name]))
      else
        reply(sock, frame.cmd, "\x01")
      end
    when Cmd::GET_FILE
      content = @files.fetch(p, "listening-data")
      reply(sock, frame.cmd, [0, p.bytesize].pack("C2") + p + [content.bytesize].pack("V") + Digest::SHA256.digest(content))
      sock.write(content)
    when Cmd::UPLOAD_FILE
      n = p.getbyte(0)
      name = p.byteslice(1, n)
      size = p.byteslice(1 + n, 4).unpack1("V")
      sha = p.byteslice(5 + n, 32)
      @upload_headers += 1
      if @silent_uploads.include?(@upload_headers) # never answer
        @resets_pending = @reset_after_drop.to_i
        return nil
      end
      if @upload_refusal
        reply(sock, frame.cmd, [@upload_refusal].pack("C"))
        return nil
      end
      if @files[name] && Digest::SHA256.digest(@files[name]) == sha
        reply(sock, frame.cmd, "\x01")
        return nil
      end
      reply(sock, frame.cmd, "\x00")
      return { name: name, size: size, sha: sha, data: "".b }
    else
      reply(sock, Cmd::UNKNOWN, "\x00")
    end
    nil
  end

  def reply(sock, cmd, payload)
    sock.write(Merlin::Protocol.encode(cmd, payload.b))
  end
end
