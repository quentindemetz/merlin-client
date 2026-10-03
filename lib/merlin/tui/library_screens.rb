# frozen_string_literal: true

require "shellwords"

module Merlin
  module TUI
    module Screens
      # The speaker's sections/folders (GET catalogs uses the same uuids as the
      # playlist, so local files can be attached to any real folder).
      module SpeakerTree
        def speaker_tree
          @speaker_tree ||= Array((app.load("Loading the speaker's folders…") { app.backend.speaker_library } || {})["treeStructure"])
        end

        def sections = speaker_tree.select { _1["child"].is_a?(Array) }
        def section_folders(section) = Array(section["child"]).select { _1["child"].is_a?(Array) }

        # uuid => "Section › Folder" (and sections => "Section").
        def place_names
          sections.each_with_object({}) do |s, names|
            names[s["uuid"]] = s["title"]
            section_folders(s).each { |f| names[f["uuid"]] = "#{s['title']} › #{f['title']}" }
          end
        end
      end

      class LocalLibraryScreen < ListScreen
        include SpeakerTree

        def title = "My audio files"
        def extra_hints = [%w[i import], ["n", "new folder"], %w[r rename], %w[x remove]]

        def on_resume
          @library = nil
          reload!
        end

        def library = @library ||= app.library

        def build_rows
          if library.empty?
            return [Row.text("Nothing imported yet. Press i to import audio files or folders (drag & drop works)."),
                    Row.text("They are added to the speaker at the next sync, where you choose.")]
          end

          names = place_names
          rows = []
          library.tracks.map(&:parent).uniq.reject { library.find(_1) }.each do |parent|
            rows << Row.header(names[parent] ? "📁 #{names[parent]}" : "📁 #{LocalLibrary::FALLBACK_FOLDER} (original folder is gone)")
            library.children(parent).each { rows << track_row(_1) }
          end
          library.folders.each do |f|
            rows << Row.header("📁 #{names[f.parent] || '?'}")
            rows << Row.item("📁 #{f.title}  (your folder)", f.uuid, markable: true)
            library.children(f.uuid).each { rows << track_row(_1, "    ") }
          end
          rows
        end

        def on_key(event)
          case event.to_s
          when "i" then ask_paths
          when "n" then app.push(DestinationScreen.new(app, mode: :folder))
          when "r" then rename_current
          when "x" then remove_targets
          end
        end

        private

        def track_row(t, indent = "")
          Row.item("#{indent}🎵 #{t.title}  #{Catalog::V.duration(t.duration)}".rstrip, t.uuid, markable: true)
        end

        def ask_paths
          app.push(InputScreen.new(app, "Import audio", label: "Path(s)") do |text|
            files = LocalLibrary.audio_files(ImportPaths.parse(text))
            next app.error("No audio files found there") if files.empty?

            Media.require_ffmpeg!
            app.pop
            app.push(DestinationScreen.new(app, files: files))
          rescue Error => e
            app.error(e.message)
          end)
        end

        def rename_current
          entry = current && library.find(current.value)
          return app.error("Put the cursor on one of your files or folders") unless entry

          app.push(InputScreen.new(app, "Rename", label: "Title", value: entry.title) do |title|
            library.rename(entry.uuid, title)
            app.pop
            app.notify("Renamed to #{title}")
          end)
        end

        def remove_targets
          uuids = targets
          return app.error("Mark items with space (or put the cursor on one) first") if uuids.empty?

          uuids.each { library.remove(_1) }
          app.notify("#{uuids.size} item(s) removed — the speaker drops them at the next sync")
          on_resume
        end
      end

      # Where imported files (or a new folder) go: speaker folders, your
      # folders, or a new folder inside one of the speaker's sections.
      class DestinationScreen < ListScreen
        include SpeakerTree

        def initialize(app, files: [], mode: :tracks)
          super(app)
          @files = files
          @mode = mode
        end

        def title = @mode == :folder ? "New folder in…" : "Add #{@files.size} file(s) to…"

        def build_rows
          return [Row.text("The speaker has no sections yet — sync once first.")] if sections.empty?

          library = app.library
          sections.flat_map do |s|
            rows = [Row.header(s["title"])]
            if @mode == :tracks
              section_folders(s).each { |f| rows << Row.item("📁 #{f['title']}", [:folder, f["uuid"]]) }
              library.folders.select { _1.parent == s["uuid"] }.each { |f| rows << Row.item("📁 #{f.title}  (your folder)", [:folder, f.uuid]) }
            end
            rows << Row.item("➕ New folder in #{s['title']}…", [:new_folder, s["uuid"], s["title"]])
          end
        end

        def activate(row)
          kind, uuid, section_title = row.value
          case kind
          when :folder then import_into(uuid)
          when :new_folder then ask_folder_name(uuid, section_title)
          end
        end

        private

        def ask_folder_name(section_uuid, section_title)
          app.push(InputScreen.new(app, "New folder in #{section_title}", label: "Name") do |name|
            folder = app.load("Creating folder…") { app.library.add_folder(name, parent: section_uuid) }
            app.pop # name input
            next unless folder

            @mode == :folder ? finish("Folder #{folder.title} created in #{section_title}") : import_into(folder.uuid)
          end)
        end

        def import_into(parent)
          library = app.library
          done = Hash.new(0)
          failed = []
          @files.each_with_index do |path, i|
            result = app.load("Importing #{i + 1}/#{@files.size}: #{File.basename(path)}…") { library.import(path, parent: parent) }
            result ? done[result.last] += 1 : failed << File.basename(path)
          end
          imported = done.values.sum
          msg = "#{imported} file(s) imported" \
                "#{" (#{done[:transcoded]} transcoded)" if done[:transcoded].positive?} — added to the speaker at the next sync"
          msg += "; failed: #{failed.join(', ')}" unless failed.empty?
          imported.zero? ? app.error(msg) : finish(msg)
        end

        def finish(msg)
          app.pop
          app.notify(msg)
        end
      end

      # Paths typed or dropped into the terminal: shell-quoted or with
      # backslash-escaped spaces ("My\ Song.mp3"), possibly several at once.
      module ImportPaths
        module_function

        def parse(text)
          text = text.strip
          return [] if text.empty?
          return [text] if File.exist?(File.expand_path(text)) # a single path with plain spaces

          Shellwords.split(text)
        rescue ArgumentError # unbalanced quotes
          [text]
        end
      end
    end
  end
end
