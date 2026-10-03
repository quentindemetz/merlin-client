# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"
require "tempfile"
require "zlib"

module Merlin
  # Turns arbitrary audio files into what the speaker plays, using ffmpeg.
  #
  # The speaker's own files are MP3, 44.1 kHz, either mono 64 kbps or stereo
  # 128 kbps, each with a 128x128 JPEG cover. MP3s already in that range are
  # copied untouched; anything else is transcoded.
  module Media
    module_function

    AUDIO_EXTENSIONS = %w[.mp3 .m4a .m4b .aac .wav .aiff .aif .flac .ogg .oga .opus .wma .mp4 .webm .caf].freeze
    COVER_SIZE = 128
    DEFAULT_COVER_COLOR = "0xF2A900"

    Info = Data.define(:title, :duration, :codec, :sample_rate, :channels, :bit_rate, :has_cover)

    def available? = system("ffmpeg", "-version", out: File::NULL, err: File::NULL) &&
                     system("ffprobe", "-version", out: File::NULL, err: File::NULL)

    def require_ffmpeg!
      raise Error, "ffmpeg is needed to import audio (brew install ffmpeg)" unless available?
    end

    def probe(path)
      out, status = Open3.capture2e("ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path)
      raise Error, "can't read #{File.basename(path)}: #{out.strip.lines.last}" unless status.success?

      data = JSON.parse(out)
      audio = Array(data["streams"]).find { _1["codec_type"] == "audio" }
      raise Error, "#{File.basename(path)} has no audio" unless audio

      tags = (data.dig("format", "tags") || {}).transform_keys(&:downcase)
      Info.new(
        title: tags["title"].to_s.strip.then { _1.empty? ? nil : _1 },
        duration: data.dig("format", "duration").to_f.round,
        codec: audio["codec_name"],
        sample_rate: audio["sample_rate"].to_i,
        channels: audio["channels"].to_i,
        bit_rate: (audio["bit_rate"] || data.dig("format", "bit_rate")).to_i,
        has_cover: Array(data["streams"]).any? { _1["codec_type"] == "video" }
      )
    end

    def speaker_ready?(info)
      info.codec == "mp3" && info.sample_rate == 44_100 && info.channels.between?(1, 2) &&
        info.bit_rate.positive? && info.bit_rate <= 192_000
    end

    # Writes the speaker-ready MP3 to dest. Returns :copied or :transcoded.
    def prepare_audio(src, dest, info = probe(src))
      FileUtils.mkdir_p(File.dirname(dest))
      if speaker_ready?(info)
        FileUtils.cp(src, dest)
        return :copied
      end

      mono = info.channels == 1
      ffmpeg!("-i", src, "-map", "0:a:0", "-vn", "-ac", mono ? "1" : "2", "-ar", "44100",
              "-c:a", "libmp3lame", "-b:a", mono ? "64k" : "128k", "-map_metadata", "-1", dest)
      :transcoded
    end

    # 128x128 JPEG from the file's embedded artwork, or a plain default.
    def prepare_cover(src, dest, info = probe(src))
      FileUtils.mkdir_p(File.dirname(dest))
      if info.has_cover
        begin
          crop = "scale=#{COVER_SIZE}:#{COVER_SIZE}:force_original_aspect_ratio=increase,crop=#{COVER_SIZE}:#{COVER_SIZE}"
          ffmpeg!("-i", src, "-an", "-map", "0:v:0", "-frames:v", "1", "-vf", crop, "-q:v", "3", dest)
          return :embedded
        rescue Error
          nil # fall back to the default cover
        end
      end
      default_cover(dest)
      :default
    end

    # The speaker doesn't show folder names, only covers: render the name on
    # a colored square (ImageMagick's caption: picks the biggest font that
    # fits). Colors come from the name, so folders look distinct but stable.
    FOLDER_COLORS = %w[#E4572E #2E86AB #8E44AD #27AE60 #D35400 #C0392B #16A085 #34495E].freeze
    FOLDER_FONTS = ["/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
                    "/System/Library/Fonts/Supplemental/Arial Bold.ttf"].freeze

    def imagemagick? = system("magick", "-version", out: File::NULL, err: File::NULL)

    # Returns :titled, or :default when ImageMagick isn't installed.
    def folder_cover(title, dest)
      unless imagemagick?
        default_cover(dest)
        return :default
      end

      FileUtils.mkdir_p(File.dirname(dest))
      color = FOLDER_COLORS[Zlib.crc32(title) % FOLDER_COLORS.size]
      font = FOLDER_FONTS.find { File.exist?(_1) }
      inner = COVER_SIZE - 16
      Tempfile.create(["merlin-title", ".txt"]) do |text|
        text.write(title)
        text.flush
        # caption:@file: the text is read verbatim (no '@'/'%' interpretation).
        args = ["magick", "-size", "#{inner}x#{inner}", "-background", color, "-fill", "white",
                *(font ? ["-font", font] : []), "-gravity", "center", "caption:@#{text.path}",
                "-extent", "#{COVER_SIZE}x#{COVER_SIZE}", "-quality", "90", dest]
        out, status = Open3.capture2e(*args)
        raise Error, "cover for #{title.inspect} failed: #{out.strip.lines.last}" unless status.success?
      end
      :titled
    end

    def default_cover(dest)
      FileUtils.mkdir_p(File.dirname(dest))
      ffmpeg!("-f", "lavfi", "-i", "color=c=#{DEFAULT_COVER_COLOR}:s=#{COVER_SIZE}x#{COVER_SIZE}", "-frames:v", "1", dest)
    end

    def ffmpeg!(*args)
      out, status = Open3.capture2e("ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *args)
      raise Error, "ffmpeg failed: #{out.strip.lines.last || 'unknown error'}" unless status.success?
    end
  end
end
