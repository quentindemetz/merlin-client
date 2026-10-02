# frozen_string_literal: true

module Merlin
  # Plain-text rendering of catalog API responses. Every line shows the kind
  # and id to feed into the next command (page / taxon / collection / content).
  module CatalogView
    module_function

    def page(page)
      lines = [page["title"].to_s]
      Array(page["modules"]).each do |mod|
        lines << ""
        lines << "== #{mod['title'] || mod['format']}#{" — #{mod['description']}" if present?(mod['description'])}"
        items = mod["elements"] || mod["items"] || []
        items.each { |item| lines << "  #{module_item(mod['format'], item)}" }
      end
      lines.join("\n")
    end

    def taxonomy(root)
      lines = [root["title"].to_s]
      lines << root["description"] if present?(root["description"])
      lines << ""
      Array(root["elements"]).each { |el| lines << "  #{element(el)}" }
      lines.join("\n")
    end

    def collection(col)
      lines = ["[collection] #{col['id']}  #{col['title']}"]
      meta = [ages(col), episodes(col), duration(col["duration"]), col["status"], col["price"]].compact
      lines << "  #{meta.join(' · ')}" unless meta.empty?
      lines << "  #{col['description']}" if present?(col["description"])
      Array(col["contents"]).sort_by { |c| c["episode"].to_i }.each do |c|
        lines << "    #{content_line(c)}"
      end
      lines.join("\n")
    end

    def content(c)
      lines = [content_line(c)]
      parent = c["collection"]
      lines << "  in [collection] #{parent['id']}  #{parent['title']}" if parent
      %w[author narrator].each { |k| lines << "  #{k}: #{c[k]}" if present?(c[k]) }
      meta = [ages(c), c["audio_size"] && "#{(c['audio_size'] / 1_048_576.0).round(1)} MB"].compact
      lines << "  #{meta.join(' · ')}" unless meta.empty?
      lines << "  #{c['description']}" if present?(c["description"])
      lines.join("\n")
    end

    def search(results)
      Array(results).map { |r| element(r) }.join("\n")
    end

    # Tree from GET catalogs: what is / will be on the speaker.
    def library(root, depth = 0, out = [])
      Array(root.is_a?(Hash) ? root["treeStructure"] || root["child"] : root).each do |item|
        flags = []
        flags << "pending add" if item["add"]
        flags << "selected" if item["selection"]
        flags << "new in last sync" if item["isInLastSync"]
        out << "#{'  ' * depth}#{item['child'] ? '▸' : '•'} #{item['title']}  (#{item['type']} #{item['uuid']})" \
               "#{" [#{flags.join(', ')}]" unless flags.empty?}"
        library(item, depth + 1, out) if item["child"]
      end
      out.join("\n")
    end

    def selections(entries)
      entries = Array(entries)
      return "(no pending selection)" if entries.empty?

      entries.map do |e|
        c = e["content"] || {}
        "#{e['add'] ? '+ add   ' : '- remove'} [content] #{c['id']}  #{c['title']}"
      end.join("\n")
    end

    def packs(list)
      Array(list).map { |p| "[pack] #{p['id']}  #{p['title']}" }.join("\n")
    end

    # --- items ---------------------------------------------------------------

    def module_item(format, item)
      case format
      when /\Ataxon/ then taxon(item)
      when "website_purchase" then "[pack] #{item.dig('pack', 'id')}  #{item.dig('pack', 'title')}"
      else element(item)
      end
    end

    def taxon(t)
      target = present?(t["subpageid"]) ? "→ page #{t['subpageid']}" : "→ taxon #{t['id']}"
      "[taxon] #{t['id']}  #{t['title']}  #{target}"
    end

    # An element wraps exactly one of collection / content / pack / webradio.
    def element(el)
      if (c = el["collection"])
        meta = [ages(c), episodes(c)].compact.join(", ")
        "[collection] #{c['id']}  #{c['title']}#{"  (#{meta})" unless meta.empty?}"
      elsif (c = el["content"]) then content_line(c)
      elsif (p = el["pack"]) then "[pack] #{p['id']}  #{p['title']}"
      elsif (w = el["webradio"]) then "[webradio] #{w['id']}  #{w['title']}"
      else "[?] #{el.to_s[0, 80]}"
      end
    end

    def content_line(c)
      ep = c["episode"].to_i.positive? ? "ep#{c['episode']} " : ""
      flags = []
      flags << "on speaker" if c["onDevice"]
      flags << "selected" if c["selected"]
      flags << "not downloadable" if c["downloadable"] == false
      "[content] #{c['id']}  #{ep}#{c['title']}  #{duration(c['duration'])}" \
        "#{" [#{flags.join(', ')}]" unless flags.empty?}".rstrip
    end

    def ages(x)
      return nil unless x["min_age"] || x["max_age"]

      "#{x['min_age']}-#{x['max_age']} ans"
    end

    def episodes(x) = x["nb_episode"].to_i.positive? ? "#{x['nb_episode']} ép." : nil

    def duration(secs)
      return nil if secs.nil?

      secs = secs.to_i
      secs >= 3600 ? format("%dh%02d", secs / 3600, secs % 3600 / 60) : format("%d:%02d", secs / 60, secs % 60)
    end

    def present?(s) = !s.nil? && !s.to_s.strip.empty?
  end
end
