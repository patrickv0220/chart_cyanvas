# frozen_string_literal: true
require "counter_culture"

class Chart < ApplicationRecord
  include ActionView::Helpers::DateHelper

  has_many :co_authors, dependent: :destroy
  belongs_to :author, class_name: "User"
  counter_culture :author,
                  column_name:
                    proc { |model|
                      model.visibility_public? ? "charts_count" : nil
                    },
                  column_names: {
                    ["charts.visibility = ?", 1] => "charts_count"
                  }

  has_many :file_resources, dependent: :destroy
  has_many :_variants,
           class_name: "Chart",
           foreign_key: "variant_id",
           dependent: :nullify,
           inverse_of: :variant_of
  belongs_to :variant_of,
             class_name: "Chart",
             optional: true,
             foreign_key: "variant_id",
             inverse_of: :_variants
  has_many :likes, dependent: :destroy
  has_many :tags, dependent: :destroy
  enum :chart_type, { sus: 0, mmws: 1, chs: 2, vusc: 3, ccmmws: 4 }

  VISIBILITY = { private: 0, public: 1, scheduled: 2 }.freeze
  enum :visibility, VISIBILITY, prefix: "visibility"

  GENRES = {
    vocal_synth: 1,
    music_game: 2,
    game: 3,
    meme: 4,
    pops: 5,
    instrumental: 6,
    others: 0
  }.freeze
  enum :genre, GENRES, prefix: true

  def self.include_all
    preload(%i[author co_authors _variants tags file_resources likes]).merge(
      FileResource.with_attached_file
    ).preload(:variant_of)
  end

  scope :sonolus_listed, -> { where(variant_id: nil) }
  def resources
    base = file_resources
    {
      chart: base.find(&:chart?),
      bgm: base.find(&:bgm?),
      cover: base.find(&:cover?),
      preview: base.find(&:preview?),
      data: base.find(&:data?),
      background_v1: base.find(&:background_v1?),
      background_v3: base.find(&:background_v3?),
      background_tablet_v1: base.find(&:background_tablet_v1?),
      background_tablet_v3: base.find(&:background_tablet_v3?)
    }
  end

  def variants(include_private: false)
    include_private ? _variants : _variants.where(visibility: :public)
  end

  def to_frontend(user: nil, with_resources: true, with_variants: false)
    resources = with_resources ? self.resources : {}
    likes = likes_count
    {
      name:,
      title:,
      composer:,
      artist:,
      author: author.to_frontend,
      authorName: author_name,
      coAuthors: co_authors.map(&:to_frontend),
      cover: resources[:cover]&.to_frontend,
      bgm: resources[:bgm]&.to_frontend,
      chart: is_chart_public? ? resources[:chart]&.to_frontend : nil,
      data: resources[:data]&.to_frontend,
      variants:
        (
          if with_variants
            variants.map { |v| v.to_frontend(with_variants: false) }
          else
            []
          end
        ),
      tags: tags.map(&:name),
      genre:,
      publishedAt: published_at&.iso8601,
      updatedAt: updated_at.iso8601,
      rating:,
      likes:,
      liked: user ? likes.exists?(user:) : false,
      description:,
      visibility:,
      scheduledAt: scheduled_at&.iso8601,
      variantOf:
        with_variants && variant_id &&
          variant_of.to_frontend(with_variants: false)
    }
  end

  def to_sonolus(background_version: :v3)
    resources = self.resources
    {
      name: "chcy-#{name}",
      title:,
      artists: "#{composer} / #{artist.presence || "-"}",
      author: "#{author_name.presence || author.name}##{author.display_handle}",
      source: ENV.fetch("FINAL_HOST", nil),
      tags: [
        { title: likes_count.to_s, icon: "heart" },
        (
          case visibility
          when "public"
            {
              title:
                I18n.t(
                  "sonolus.levels.published_at",
                  time: time_ago_in_words(published_at)
                )
            }
          when "private"
            { title: I18n.t("sonolus.levels.visibility.private") }
          when "scheduled"
            { title: I18n.t("sonolus.levels.visibility.scheduled") }
          end
        ),
        genre != "others" &&
          { title: I18n.t("sonolus.levels.genres.#{genre}") },
        *tags.map { |tag| { title: tag.name } }
      ].filter(&:itself),
      cover: resources[:cover]&.to_srl || { hash: "", url: "" },
      bgm: resources[:bgm]&.to_srl || { hash: "", url: "" },
      preview: resources[:preview]&.to_srl || { hash: "", url: "" },
      data:
        resources[:data]&.to_srl ||
          { hash: "", url: "/sonolus/generate-asset?chart=#{name}&type=data" },
      rating:,
      version: 1,
      useSkin: {
        useDefault: true
      },
      useBackground: {
        useDefault: false,
        item: to_sonolus_background(resources, version: background_version)
      },
      useEffect: {
        useDefault: true
      },
      useParticle: {
        useDefault: true
      },
      engine: Sonolus::AssetController.asset_get("engine", "pjsekai-extended")
    }
  end

  def to_sonolus_background(resources, version: :v3)
    {
      name: "chcy-bg-#{name}-#{version}",
      version: 2,
      tags: [],
      source: ENV.fetch("FINAL_HOST", nil),
      title:
        I18n.t(
          "sonolus.backgrounds.title",
          name: title,
          version: I18n.t("sonolus.backgrounds.versions.#{version}")
        ),
      subtitle: "#{composer}#{" / #{artist}" if artist.presence}",
      author: "#{author_name.presence || author.name}##{author.display_handle}",
      thumbnail: resources[:cover]&.to_srl || { hash: "", url: "" },
      data:
        Sonolus::AssetController.asset_get_static("backgrounds/data.json.gz"),
      image:
        resources[:"background_#{version}"]&.to_srl ||
          {
            hash: "",
            url:
              "/sonolus/generate-asset?chart=#{name}&type=background_#{version}"
          },
      configuration:
        Sonolus::AssetController.asset_get_static(
          "backgrounds/configuration.json.gz"
        )
    }
  end

  RANDOM_CHARTS_CACHE_COUNT = 100
  def self.get_random_chart_ids(count, genres: Chart::GENRES.keys)
    randoms = []
    genres.each do |genre|
      chart_ids =
        Rails
          .cache
          .fetch("sonolus:random_charts:#{genre}", expires_in: 1.hour) do
            chart_ids =
              Chart
                .where(genre:)
                .where(visibility: :public)
                .sonolus_listed
                .pluck(:id)
            chart_ids.sample(RANDOM_CHARTS_CACHE_COUNT)
          end
      randoms += chart_ids
    end
    randoms.sample(count)
  end

  def self.get_num_charts_with_cache(genres: Chart::GENRES.keys)
    genres.sum do |genre|
      Rails
        .cache
        .fetch("sonolus:num_charts:#{genre}", expires_in: 5.minutes) do
          Chart.where(genre:, visibility: :public).sonolus_listed.count
        end
    end
  end
end
