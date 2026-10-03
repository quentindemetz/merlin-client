# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/merlin"

# Payload shapes follow the app's Moshi models (ApiPageRepository$RawModule…,
# ApiCollectionRepository$RawCollection, ApiCatalogsRepository$RawCatalogItem…).
class CatalogViewTest < Minitest::Test
  V = Merlin::CatalogView

  def test_page_modules
    page = {
      "title" => "Accueil",
      "modules" => [
        { "format" => "taxon_slider", "title" => "Univers",
          "items" => [{ "id" => "t1", "title" => "Contes", "subpageid" => "p2" },
                      { "id" => "t2", "title" => "Musique", "subpageid" => nil }] },
        { "format" => "selection_slider", "title" => "Nouveautés", "description" => "Ce mois-ci",
          "elements" => [{ "collection" => { "id" => "c1", "title" => "Odyssées", "min_age" => 7, "max_age" => 12, "nb_episode" => 12 } },
                         { "content" => { "id" => "k1", "title" => "Le loup", "duration" => 754, "onDevice" => true } },
                         { "webradio" => { "id" => "w1", "title" => "Radio Merlin" } }] },
        { "format" => "website_purchase", "title" => "Packs", "elements" => [{ "pack" => { "id" => "pk1", "title" => "Pack été" } }] }
      ]
    }
    assert_equal <<~TXT.chomp, V.page(page)
      Accueil

      == Univers
        [taxon] t1  Contes  → page p2
        [taxon] t2  Musique  → taxon t2

      == Nouveautés — Ce mois-ci
        [collection] c1  Odyssées  (7-12 ans, 12 ép.)
        [content] k1  Le loup  12:34 [on speaker]
        [webradio] w1  Radio Merlin

      == Packs
        [pack] pk1  Pack été
    TXT
  end

  def test_collection_sorted_by_episode
    col = { "id" => "c1", "title" => "Odyssées", "min_age" => 7, "max_age" => 12, "nb_episode" => 2,
            "duration" => 4000, "contents" => [
              { "id" => "k2", "title" => "Puyi", "episode" => 2, "duration" => 600, "selected" => true },
              { "id" => "k1", "title" => "Robinson", "episode" => 1, "duration" => 61, "downloadable" => false }
            ] }
    assert_equal <<~TXT.chomp, V.collection(col)
      [collection] c1  Odyssées
        7-12 ans · 2 ép. · 1h06
          [content] k1  ep1 Robinson  1:01 [not downloadable]
          [content] k2  ep2 Puyi  10:00 [selected]
    TXT
  end

  def test_library_tree_and_basket
    lib = { "treeStructure" => [
      { "uuid" => "f1", "title" => "Contes", "type" => "folder", "child" => [
        { "uuid" => "a1", "title" => "Le loup", "type" => "audio", "isInLastSync" => true },
        { "uuid" => "a2", "title" => "Ours", "type" => "audio", "add" => true }
      ] }
    ] }
    assert_equal <<~TXT.chomp, V.library(lib)
      ▸ Contes  (folder f1)
        • Le loup  (audio a1) [new in last sync]
        • Ours  (audio a2) [pending add]
    TXT
    assert_equal "+ add    [content] c1  Le loup\n- remove [content] c2  Ours",
                 V.selections([{ "add" => true, "content" => { "id" => "c1", "title" => "Le loup" } },
                               { "add" => false, "content" => { "id" => "c2", "title" => "Ours" } }])
    assert_equal "(no pending selection)", V.selections([])
  end

  # Shapes seen in the real API responses (HTTP log, 2026-10-02/03).
  def test_ages
    assert_nil V.ages("min_age" => 0, "max_age" => 0), "0/0 means 'not set' (nearly every episode)"
    assert_nil V.ages({})
    assert_equal "7-15 ans", V.ages("min_age" => 7, "max_age" => 15)
    assert_equal "5 ans et +", V.ages("min_age" => 5, "max_age" => 0)
    assert_equal "jusqu'à 6 ans", V.ages("min_age" => 0, "max_age" => 6)
    tagged = { "min_age" => 0, "max_age" => 0,
               "taxonomies" => [{ "type" => "CATEGORY", "title" => "Documentaires" },
                                { "type" => "TAG", "title" => "Entre 5 et 15 minutes" },
                                { "type" => "TAG", "title" => "7 ans et +" }] }
    assert_equal "7 ans et +", V.ages(tagged)
  end

  def test_unset_age_is_not_displayed
    assert_equal "[collection] c1  Odyssées  (12 ép.)",
                 V.element("collection" => { "id" => "c1", "title" => "Odyssées", "min_age" => 0, "max_age" => 0, "nb_episode" => 12 })
  end

  def test_search_results
    assert_equal "[collection] c1  Odyssées\n[content] k1  Le loup",
                 V.search([{ "collection" => { "id" => "c1", "title" => "Odyssées" } },
                           { "content" => { "id" => "k1", "title" => "Le loup" } }])
  end
end
