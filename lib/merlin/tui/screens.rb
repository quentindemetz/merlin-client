# frozen_string_literal: true

require "set"

module Merlin
  module TUI
    module Screens
      # A row of a ListScreen. kind: :item (selectable), :header, :text.
      Row = Data.define(:label, :value, :kind, :markable) do
        def self.item(label, value = nil, markable: false) = new(label, value, :item, markable)
        def self.header(label) = new(label, nil, :header, false)
        def self.text(label) = new(label, nil, :text, false)
        def selectable? = kind == :item
      end

      class Screen
        attr_reader :app

        def initialize(app)
          @app = app
        end

        def title = ""
        def hints = [["esc", "back"]]
        def on_enter = nil
        def on_resume = nil
        def busy? = false
        def tui = app.tui

        def handle(event)
          app.pop if %i[esc left].include?(event.to_sym)
        end

        def render(frame, area); end
      end

      # Scrollable list with cursor, optional marks (space) and an optional
      # intro panel (description etc.) above it.
      class ListScreen < Screen
        PAGE = 10

        def initialize(app)
          super
          @index = 0
          @marked = Set.new
        end

        # Built lazily (build_rows may hit the network); while building, renders
        # triggered by the loading indicator see a placeholder instead of
        # re-entering build_rows.
        def rows
          return @rows if @rows
          return [Row.text("Loading…")] if @building

          @building = true
          begin
            @rows = build_rows
          ensure
            @building = false
          end
        end

        def build_rows = []
        def intro = nil # Array of strings shown above the list

        def reload!
          @rows = nil
          @marked.clear
          @index = 0 if @index >= rows.size
          snap(1)
        end

        def on_enter
          snap(1)
        end

        def current = rows[@index]&.then { |r| r.selectable? ? r : nil }

        # Marked values, or the current row's value when nothing is marked.
        def targets
          return @marked.to_a unless @marked.empty?

          current&.markable ? [current.value] : []
        end

        def hints
          h = [%w[↑↓ move], %w[enter open]]
          h << %w[space mark] if rows.any?(&:markable)
          h + extra_hints + [%w[esc back]]
        end

        def extra_hints = []

        def handle(event)
          case event.to_sym
          when :up, :k then move(-1)
          when :down, :j then move(1)
          when :page_up then move(-PAGE)
          when :page_down then move(PAGE)
          when :home then (@index = 0) && snap(1)
          when :end then (@index = rows.size - 1) && snap(-1)
          when :enter, :right then current && activate(current)
          when :space, :" " then toggle_mark # terminals report space as " "
          when :esc, :left, :backspace then app.pop
          else on_key(event)
          end
        end

        def activate(row); end
        def on_key(event); end

        def render(frame, area)
          list_area = area
          if (lines = intro) && !lines.empty?
            inner = [area.width - 2, 1].max
            height = lines.sum { |l| [(tui.text_width(l) + inner - 1) / inner, 1].max } + 2
            top, list_area = tui.layout_split(area, direction: :vertical,
                                                    constraints: [tui.constraint_length([height, area.height / 2].min),
                                                                  tui.constraint_fill(1)])
            frame.render_widget(tui.paragraph(text: lines.join("\n"), wrap: true,
                                              block: tui.block(borders: [:all], border_style: app.style(fg: :dark_gray))), top)
          end
          frame.render_widget(
            tui.list(items: rows.map { |r| list_item(r) }, selected_index: rows.empty? ? nil : @index,
                     highlight_style: app.style(fg: :black, bg: :cyan), highlight_symbol: "▶ ",
                     highlight_spacing: :always,
                     block: tui.block(title: " #{title} ", borders: [:all], border_style: app.style(fg: :cyan))),
            list_area
          )
        end

        private

        def list_item(row)
          case row.kind
          when :header then tui.list_item(content: row.label, style: app.style(fg: :yellow, modifiers: [:bold]))
          when :text then tui.list_item(content: row.label, style: app.style(fg: :dark_gray))
          else
            mark = row.markable ? (@marked.include?(row.value) ? "[x] " : "[ ] ") : ""
            indent = row.label[/\A */]
            tui.list_item(content: indent + mark + row.label.delete_prefix(indent))
          end
        end

        def toggle_mark
          row = current
          return unless row&.markable

          @marked.include?(row.value) ? @marked.delete(row.value) : @marked.add(row.value)
          move(1)
        end

        def move(delta)
          return if rows.empty?

          @index = (@index + delta).clamp(0, rows.size - 1)
          snap(delta.positive? ? 1 : -1)
        end

        # Move to the nearest selectable row in +dir+, else the other way.
        def snap(dir)
          return if rows.empty?

          [dir, -dir].each do |d|
            i = @index
            i += d while i.between?(0, rows.size - 1) && !rows[i].selectable?
            return @index = i if i.between?(0, rows.size - 1)
          end
        end
      end

      # Shared catalog helpers: labels without ids and add/remove actions.
      module Catalog
        V = Merlin::CatalogView

        def element_row(el)
          if (c = el["collection"])
            meta = [V.ages(c), V.episodes(c)].compact.join(", ")
            Row.item("📚 #{c['title']}#{"  (#{meta})" unless meta.empty?}", [:collection, c["id"], c["title"]])
          elsif (c = el["content"])
            Row.item("🎧 #{content_label(c)}", [:content, c["id"], c["title"]], markable: true)
          elsif (p = el["pack"]) then Row.item("🎁 #{p['title']}", [:pack, p["id"], p["title"]])
          elsif (w = el["webradio"]) then Row.item("📻 #{w['title']}", [:webradio, w["id"], w["title"]])
          end
        end

        def taxon_row(t)
          target = V.present?(t["subpageid"]) ? [:page, t["subpageid"], t["title"]] : [:taxon, t["id"], t["title"]]
          Row.item("▸ #{t['title']}", target)
        end

        def content_label(c)
          ep = c["episode"].to_i.positive? ? "#{c['episode']}. " : ""
          flags = []
          flags << "on speaker" if c["onDevice"]
          flags << "selected" if c["selected"]
          "#{ep}#{c['title']}  #{V.duration(c['duration'])}#{"  [#{flags.join(', ')}]" unless flags.empty?}".rstrip
        end

        def open(value)
          kind, id, label = value
          case kind
          when :page then app.push(PageScreen.new(app, id, label))
          when :taxon then app.push(TaxonScreen.new(app, id, label))
          when :collection then app.push(CollectionScreen.new(app, id))
          when :content then app.push(ContentScreen.new(app, id))
          when :pack then app.push(PackScreen.new(app, id, label))
          when :webradio then app.notify("Webradios can't be browsed further")
          end
        end

        # Values are [:content, id, title] tuples.
        def queue_contents(values, add:)
          ids = values.select { |v| v.is_a?(Array) ? v.first == :content : true }.map { |v| v.is_a?(Array) ? v[1] : v }
          return app.error("Mark contents with space (or put the cursor on one) first") if ids.empty?

          entries = app.load(add ? "Adding…" : "Queueing removal…") { app.backend.select_contents(ids, add: add) }
          return unless entries

          app.basket_count = Array(entries).size
          app.notify("#{ids.size} item(s) #{add ? 'queued for the speaker' : 'queued for removal'} — sync to apply")
          true
        end

        def queue_collection(id, title)
          entries = app.load("Adding collection…") { app.backend.select_collection(id) }
          return unless entries

          app.basket_count = Array(entries).size
          app.notify("#{title} queued for the speaker — sync to apply")
        end
      end

      # --- Main menu -----------------------------------------------------------

      class MainMenu < ListScreen
        def title = "Menu"

        def on_enter
          app.refresh_basket_count if app.logged_in?
          super
        end

        def on_resume
          @rows = nil
          on_enter
        end

        def build_rows
          return [Row.item("🔑 Log in", :login), Row.item("Quit", :quit)] unless app.logged_in?

          speaker = app.current_speaker&.dig("speaker_name") || "(none selected)"
          [
            Row.header("Account"),
            Row.item("🔈 Speaker: #{speaker}", :speakers),
            Row.item("🚪 Log out", :logout),
            Row.header("Content"),
            Row.item("📦 On my speaker", :library),
            Row.item("🌍 Browse the catalog", :browse),
            Row.item("🔎 Search the catalog", :search),
            Row.item("🧺 Basket#{" (#{app.basket_count})" if app.basket_count}", :basket),
            Row.item("🎵 My audio files", :local),
            Row.header("Transfer"),
            Row.item("🔄 Sync now", :sync),
            Row.text(""),
            Row.item("Quit", :quit)
          ]
        end

        def hints = [%w[↑↓ move], %w[enter select], %w[q quit]]

        def handle(event)
          return app.quit if event == "q" || event.to_sym == :esc

          super
        end

        def activate(row)
          case row.value
          when :login then app.push(LoginScreen.new(app))
          when :logout
            app.backend.logout
            app.forget_account
            app.notify("Logged out")
            on_resume
          when :speakers then app.push(SpeakersScreen.new(app))
          when :quit then app.quit
          else
            return app.error("Select a speaker first") unless app.config.setting_id

            case row.value
            when :library then app.push(LibraryScreen.new(app))
            when :browse then browse_home
            when :search then app.push(InputScreen.new(app, "Search the catalog") { |q| search(q) })
            when :basket then app.push(BasketScreen.new(app))
            when :local then app.push(LocalLibraryScreen.new(app))
            when :sync then app.push(SyncScreen.new(app))
            end
          end
        end

        private

        def browse_home
          id = app.load { app.backend.home_page_id }
          return app.error("Your account has no catalog home page") if id.nil? && app.screen == self

          app.push(PageScreen.new(app, id, "Catalog")) if id
        end

        def search(query)
          results = app.load("Searching…") { app.backend.search(query) }
          app.pop # the input screen
          app.push(ResultsScreen.new(app, "Search: #{query}", results)) if results
        end
      end

      # --- Text input ------------------------------------------------------------

      # One or more text fields; Tab / ↑↓ move between them, Enter submits.
      class FormScreen < Screen
        Field = Struct.new(:label, :value, :secret)

        def initialize(app, title, fields, &on_submit)
          super(app)
          @title = title
          @fields = fields.map { |label, secret, value| Field.new(label, +value.to_s, secret) }
          @focus = 0
          @on_submit = on_submit
        end

        def title = @title
        def hints = [%w[tab next\ field], %w[enter submit], %w[esc cancel]]

        def handle(event)
          case event.to_sym
          when :esc then app.pop
          when :tab, :down then @focus = (@focus + 1) % @fields.size
          when :back_tab, :up then @focus = (@focus - 1) % @fields.size
          when :backspace then @fields[@focus].value.chop!
          when :enter
            if @focus < @fields.size - 1 then @focus += 1
            else @on_submit.call(*@fields.map(&:value))
            end
          else
            ch = event.to_s
            @fields[@focus].value << ch if ch.length == 1 && (event.modifiers - ["shift"]).empty?
          end
        end

        def handle_paste(text) = @fields[@focus].value << text.delete("\r\n")

        def render(frame, area)
          width = [area.width - 4, 60].min
          box = tui.rect(x: area.x + 2, y: area.y + 1, width: width, height: @fields.size * 2 + 3)
          lines = @fields.each_with_index.flat_map do |f, i|
            shown = f.secret ? "•" * f.value.size : f.value
            focused = i == @focus
            [tui.line(spans: [tui.span(content: " #{f.label.ljust(10)} ", style: app.style(fg: :cyan)),
                              tui.span(content: "#{shown}#{'█' if focused}",
                                       style: focused ? app.style(modifiers: [:bold]) : nil)]),
             tui.line(spans: [])]
          end
          frame.render_widget(tui.paragraph(text: lines, block: tui.block(title: " #{title} ", borders: [:all],
                                                                          border_style: app.style(fg: :cyan))), box)
        end
      end

      class InputScreen < FormScreen
        def initialize(app, title, label: "Query", value: nil, &on_submit)
          super(app, title, [[label, false, value]]) do |value|
            value.strip.empty? ? app.error("Type something first") : on_submit.call(value.strip)
          end
        end
      end

      class LoginScreen < FormScreen
        def initialize(app)
          super(app, "Log in to Hello Merlin", [["Email"], ["Password", true]]) do |email, password|
            submit(email, password)
          end
        end

        private

        def submit(email, password)
          return app.error("Email and password are required") if email.strip.empty? || password.empty?

          return unless app.load("Logging in…") { app.backend.login(email, password) }

          app.forget_account
          list = app.load("Loading speakers…") { app.speakers } || []
          app.select_speaker(list.first) if list.size == 1 && !app.config.setting_id
          app.notify("Logged in as #{email.strip}")
          app.pop
          app.push(SpeakersScreen.new(app)) if list.size > 1 && !app.config.setting_id
        end
      end

      # --- Speakers --------------------------------------------------------------

      class SpeakersScreen < ListScreen
        def title = "Select your speaker"

        def build_rows
          list = app.load("Loading speakers…") { app.speakers } || []
          return [Row.text("No speaker on this account — pair one with the mobile app first.")] if list.empty?

          list.map do |s|
            current = s["id"].to_s == app.config.setting_id.to_s
            sync = s["toSyncCount"].to_i.positive? ? "  · #{s['toSyncCount']} to sync" : ""
            Row.item("#{current ? '●' : '○'} #{s['speaker_name'] || '(unnamed)'}#{sync}", s)
          end
        end

        def activate(row)
          app.select_speaker(row.value)
          app.pop
        end
      end

      # --- On the speaker --------------------------------------------------------

      class LibraryScreen < ListScreen
        include Catalog

        def title = "On my speaker"
        def extra_hints = [%w[d remove], %w[c catalog], %w[r refresh]]

        def build_rows
          data = app.load("Loading speaker content…") { app.backend.speaker_library }
          return [Row.text("Could not load the speaker library.")] unless data

          rows = []
          walk(Array(data["treeStructure"]), 0, rows)
          rows.empty? ? [Row.text("Nothing on the speaker yet — press c to browse the catalog.")] : rows
        end

        def activate(row)
          open([:content, row.value, nil]) if row.markable
        end

        def on_key(event)
          case event.to_s
          when "d" then queue_contents(targets, add: false) && reload!
          when "c" then browse
          when "r" then reload!
          end
        end

        private

        def browse
          id = app.load { app.backend.home_page_id }
          app.push(PageScreen.new(app, id, "Catalog")) if id
        end

        def walk(items, depth, rows)
          items.each do |item|
            indent = "  " * depth
            if item["child"].is_a?(Array) && !item["child"].empty?
              rows << Row.header("#{indent}📁 #{item['title']}")
              walk(item["child"], depth + 1, rows)
            else
              rows << Row.item("#{indent}#{item['title']}#{library_flags(item)}", item["uuid"], markable: true)
            end
          end
        end

        def library_flags(item)
          flags = []
          flags << "pending add" if item["add"]
          flags << "new" if item["isInLastSync"]
          flags.empty? ? "" : "  [#{flags.join(', ')}]"
        end
      end

      # --- Catalog -----------------------------------------------------------------

      class PageScreen < ListScreen
        include Catalog

        def initialize(app, id, label = nil)
          super(app)
          @id = id
          @label = label
        end

        def title = @page&.dig("title") || @label || "Catalog"
        def extra_hints = [%w[a add]]

        def build_rows
          @page = app.load("Loading page…") { app.backend.page(@id) }
          return [Row.text("Could not load this page.")] unless @page

          Array(@page["modules"]).flat_map do |mod|
            items = (mod["elements"] || mod["items"] || []).filter_map do |item|
              mod["format"].to_s.start_with?("taxon") ? taxon_row(item) : element_row(item)
            end
            items.empty? ? [] : [Row.header(mod["title"] || mod["format"].to_s), *items]
          end
        end

        def activate(row) = open(row.value)

        def on_key(event)
          add_current if event.to_s == "a"
        end

        private

        def add_current
          kind, id, label = current&.value
          return queue_collection(id, label) if @marked.empty? && kind == :collection

          queue_contents(targets, add: true) && reload!
        end
      end

      class TaxonScreen < PageScreen
        def title = @root&.dig("title") || @label || "Category"
        def intro = @root && V.present?(@root["description"]) ? [@root["description"]] : nil

        def build_rows
          @root = app.load("Loading…") { app.backend.taxonomy(@id) }
          return [Row.text("Could not load this category.")] unless @root

          Array(@root["elements"]).filter_map { |el| element_row(el) }
        end
      end

      class ResultsScreen < PageScreen
        def initialize(app, label, results)
          super(app, nil, label)
          @results = results
        end

        def title = @label

        def build_rows
          rows = Array(@results).filter_map { |el| element_row(el) }
          rows.empty? ? [Row.text("No results.")] : rows
        end
      end

      class CollectionScreen < ListScreen
        include Catalog

        def initialize(app, id)
          super(app)
          @id = id
        end

        def title = @col&.dig("title") || "Collection"
        def extra_hints = [%w[a add], ["A", "add all"]]

        def intro
          return nil unless @col

          meta = [V.ages(@col), V.episodes(@col), V.duration(@col["duration"]), @col["status"]].compact.join(" · ")
          brands = Array(@col["brands"]).map { |b| b["title"] }.join(", ")
          [meta, brands.empty? ? nil : brands, @col["description"]].compact.reject(&:empty?)
        end

        def build_rows
          @col = app.load("Loading collection…") { app.backend.collection(@id) }
          return [Row.text("Could not load this collection.")] unless @col

          contents = Array(@col["contents"]).sort_by { |c| c["episode"].to_i }
          return [Row.text("No episode available.")] if contents.empty?

          contents.map { |c| Row.item(content_label(c), [:content, c["id"], c["title"]], markable: true) }
        end

        def activate(row) = open(row.value)

        def on_key(event)
          case event.to_s
          when "a" then queue_contents(targets, add: true) && reload!
          when "A" then queue_collection(@id, title) && reload!
          end
        end
      end

      class ContentScreen < ListScreen
        include Catalog

        def initialize(app, id)
          super(app)
          @id = id
        end

        def title = @content&.dig("title") || "Content"

        def intro
          return nil unless @content

          c = @content
          [content_label(c),
           [("by #{c['author']}" if V.present?(c["author"])), ("read by #{c['narrator']}" if V.present?(c["narrator"])),
            V.ages(c)].compact.join(" · "),
           c["description"]].compact.reject(&:empty?)
        end

        def build_rows
          @content = app.load("Loading…") { app.backend.content(@id) }
          return [Row.text("Could not load this content.")] unless @content

          rows = []
          rows << if @content["onDevice"]
                    Row.item("➖ Remove from my speaker", :remove)
                  else
                    Row.item("➕ Add to my speaker", :add)
                  end
          if (parent = @content["collection"])
            rows << Row.item("📚 Open collection: #{parent['title']}", [:collection, parent["id"], parent["title"]])
          end
          rows
        end

        def activate(row)
          case row.value
          when :add then queue_contents([@id], add: true) && reload!
          when :remove then queue_contents([@id], add: false) && reload!
          else open(row.value)
          end
        end
      end

      class PackScreen < ListScreen
        def initialize(app, id, label)
          super(app)
          @id = id
          @label = label
        end

        def title = @label || "Pack"
        def intro = @pack && Catalog::V.present?(@pack["description"]) ? [@pack["description"]] : nil

        def build_rows
          @pack = app.load("Loading pack…") { app.backend.pack_preview(@id) }
          return [Row.text("Could not load this pack.")] unless @pack

          Array(@pack["preview_contents"]).map { |c| Row.text("#{c['title']}#{"  — #{c['subtitle']}" if c['subtitle']}") } +
            [Row.text(""), Row.text("Packs are purchased on the Hello Merlin website.")]
        end
      end

      # --- Basket ------------------------------------------------------------------

      class BasketScreen < ListScreen
        def title = "Basket — applied at next sync"
        def extra_hints = [%w[x cancel], %w[s sync]]

        def build_rows
          entries = app.load("Loading basket…") { app.backend.selections }
          return [Row.text("Could not load the basket.")] unless entries

          app.basket_count = entries.size
          return [Row.text("Nothing pending. Add contents from the catalog.")] if entries.empty?

          entries.map do |e|
            c = e["content"] || {}
            Row.item("#{e['add'] ? '➕ add   ' : '➖ remove'}  #{c['title']}", c["id"], markable: true)
          end
        end

        def on_key(event)
          case event.to_s
          when "x" then cancel
          when "s" then app.push(SyncScreen.new(app))
          end
        end

        private

        def cancel
          ids = targets
          return app.error("Nothing to cancel") if ids.empty?

          entries = app.load("Cancelling…") { app.backend.cancel_selections(ids) }
          return unless entries

          app.notify("#{ids.size} entr#{ids.size == 1 ? 'y' : 'ies'} removed from the basket")
          reload!
        end
      end
    end
  end
end
