# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class LocalLibraryTest < Minitest::Test
  # Stands in for ffmpeg: writes small marker files.
  module FakeMedia
    module_function

    def probe(path) = Merlin::Media::Info.new(title: File.read(path)[/title=(.*)/, 1], duration: 90, codec: "aac",
                                              sample_rate: 48_000, channels: 2, bit_rate: 256_000, has_cover: false)
    def prepare_audio(_src, dest, _info) = File.write(dest, "MP3") && :transcoded
    def prepare_cover(_src, dest, _info) = File.write(dest, "JPG") && :default
    def folder_cover(title, dest)
      (@drawn ||= []) << title
      File.write(dest, "cover titled #{title}") && :titled
    end

    def drawn = (@drawn ||= [])
  end

  # Shape of the real playlistText (Verte, 2026-10-02): sections -> folders -> tracks.
  PLAYLIST = [
    { "uuid" => "sec-hist", "title" => "Histoires", "child" => [
      { "uuid" => "fold-belles", "title" => "Les Belles Histoires", "child" => [
        { "uuid" => "t1", "title" => "Monsieur Loup", "add_time" => 1, "limit_time" => 0, "type" => "paid" }
      ] }
    ] },
    { "uuid" => "sec-mus", "title" => "Musique", "child" => [] },
    { "uuid" => "fav", "title" => "Merlin_favorite", "favorite" => 1, "child" => [] }
  ].freeze

  def setup
    @dir = Dir.mktmpdir
    @lib = Merlin::LocalLibrary.new(dir: @dir, setting_id: "verte", media: FakeMedia)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def source(name, title: nil)
    path = File.join(@dir, name)
    File.write(path, title ? "title=#{title}" : "")
    path
  end

  def plan = { "playlistText" => JSON.generate(PLAYLIST), "fileList" => [{ "type" => "audio", "filename" => "t1.mp3" }] }

  def test_import_into_a_speaker_folder_and_a_new_folder
    a, action = @lib.import(source("loup.m4a", title: "Le loup raconté par papa"), parent: "fold-belles")
    assert_equal [:transcoded, "Le loup raconté par papa", "fold-belles"], [action, a.title, a.parent]
    folder = @lib.add_folder("Comptines de mamie", parent: "sec-mus")
    b, = @lib.import(source("une_souris_verte.wav"), parent: folder.uuid)
    assert_equal "une souris verte", b.title, "falls back to the file name"

    p = plan
    summary = @lib.merge!(p)
    assert_equal({ tracks: 2, folders: 1, relocated: [] }, summary)

    tree = JSON.parse(p["playlistText"])
    belles = tree[0]["child"][0]["child"]
    assert_equal %w[t1] + [a.uuid], belles.map { _1["uuid"] }
    assert_equal({ "uuid" => a.uuid, "title" => a.title, "add_time" => a.added_at, "limit_time" => 0, "type" => "free" }, belles.last)
    mamie = tree[1]["child"].first
    assert_equal ["Comptines de mamie", [b.uuid]], [mamie["title"], mamie["child"].map { _1["uuid"] }]
    assert_empty tree[2]["child"], "nothing goes into the favourites node"

    local = p["fileList"].drop(1)
    assert_equal ["#{folder.uuid}.jpg", "#{a.uuid}.jpg", "#{a.uuid}.mp3", "#{b.uuid}.jpg", "#{b.uuid}.mp3"], local.map { _1["filename"] }
    assert(local.all? { File.exist?(_1["path"]) })
  end

  def test_tracks_whose_folder_disappeared_go_to_mes_fichiers
    t, = @lib.import(source("x.mp3"), parent: "fold-removed-from-speaker")
    2.times do # stable folder uuid across syncs
      p = plan
      assert_equal [t.title], @lib.merge!(p)[:relocated]
      fallback = JSON.parse(p["playlistText"])[0]["child"].last
      assert_equal "Mes fichiers", fallback["title"]
      assert_equal [t.uuid], fallback["child"].map { _1["uuid"] }
      (@uuids ||= []) << fallback["uuid"]
      assert_includes p["fileList"].map { _1["filename"] }, "#{fallback['uuid']}.jpg"
    end
    assert_equal 1, @uuids.uniq.size
  end

  # The speaker shows covers, not folder names: folder covers carry the name.
  def test_folder_covers_show_the_folder_name
    f = @lib.add_folder("Comptines de mamie", parent: "sec-mus")
    assert_equal "cover titled Comptines de mamie", File.read(@lib.cover_path(f.uuid))
    @lib.rename(f.uuid, "Comptines de papi")
    assert_equal "cover titled Comptines de papi", File.read(@lib.cover_path(f.uuid))

    FakeMedia.drawn.clear
    @lib.merge!(plan)
    assert_empty FakeMedia.drawn, "up-to-date covers are not redrawn at each sync"

    File.delete(@lib.cover_path(f.uuid)) # e.g. a folder from before titled covers
    @lib.merge!(plan)
    assert_equal ["Comptines de papi"], FakeMedia.drawn
  end

  def test_fallback_folder_cover_is_titled_too
    t, = @lib.import(source("x.mp3"), parent: "gone")
    p = plan
    @lib.merge!(p)
    fallback = JSON.parse(p["playlistText"])[0]["child"].last
    assert_equal "cover titled Mes fichiers", File.read(@lib.cover_path(fallback["uuid"]))
    assert_equal [t.uuid], fallback["child"].map { _1["uuid"] }
  end

  def test_titles_are_shortened_like_the_server_does
    long = "Le plus grand chevalier de tous les temps - Avril 2025 - numéro spécial"
    assert_equal "Le plus grand chevalier de tous les temps - Avril 2025 - num...", Merlin::LocalLibrary.speaker_title(long)
    assert_operator Merlin::LocalLibrary.speaker_title("é" * 100).bytesize, :<=, 63
  end

  def test_remove_folder_removes_its_tracks_and_files
    f = @lib.add_folder("Vacances", parent: "sec-mus")
    t, = @lib.import(source("a.mp3"), parent: f.uuid)
    @lib.remove(f.uuid)
    assert @lib.empty?
    refute File.exist?(@lib.audio_path(t.uuid))
    refute File.exist?(@lib.cover_path(f.uuid))
  end

  def test_persisted_per_speaker
    @lib.import(source("a.mp3"), parent: "fold-belles")
    assert_equal 1, Merlin::LocalLibrary.new(dir: @dir, setting_id: "verte", media: FakeMedia).tracks.size
    assert Merlin::LocalLibrary.new(dir: @dir, setting_id: "bleue", media: FakeMedia).empty?
  end

  def test_audio_files_expands_folders
    sub = File.join(@dir, "album")
    FileUtils.mkdir_p(File.join(sub, "cd2"))
    %w[01.mp3 02.FLAC notes.txt cd2/03.m4a].each { File.write(File.join(sub, _1), "") }
    assert_equal %w[01.mp3 02.FLAC cd2/03.m4a], Merlin::LocalLibrary.audio_files([sub]).map { _1.delete_prefix("#{sub}/") }
    assert_raises(Merlin::Error) { Merlin::LocalLibrary.audio_files([File.join(@dir, "nope.mp3")]) }
  end

  def test_empty_library_leaves_the_plan_alone
    p = plan
    assert_equal({ tracks: 0, folders: 0, relocated: [] }, @lib.merge!(p))
    assert_equal plan, p
  end
end
