require_dependency 'keyframe'
require_dependency 'country'
require_dependency 'type_with_unit'
require_dependency 'indicator_type'
require_dependency 'unit'
require_dependency 'data_type'
require_dependency 'data_version'
require_dependency 'element'

class Presentation < ActiveRecord::Base

  class_attribute :changed_cache_enabled

  # Cache data_changed per default
  self.changed_cache_enabled = true

  belongs_to :data_version

  after_find :deserialize_keyframes
  before_save :serialize_keyframes
  after_save :restore_keyframes, :clean_renderer_cache

  def initialize(attributes = {}, options = {})
    super
    self.keyframes = []
    self.data_version = DataVersion.most_recent
  end

  def self.from_json(hash)
    hash = hash.recursive_symbolize_keys
    presentation = Presentation.new
    presentation.title = hash[:title]
    presentation.create_keyframes(hash[:keyframes])
    presentation
  end

  def as_json(options = nil)
    {
      id: id,
      title: title,
      keyframes: keyframes,
      data_version: data_version.version,
      data_changed: data_changed?,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  # Create proper Keyframe objects from an array of hashes
  def create_keyframes(raw_keyframes)
    keyframes = raw_keyframes.map do |keyframe_hash|
      Keyframe.from_json(keyframe_hash)
    end
    @keyframes_array = keyframes
    self.keyframes = keyframes
  end

  def data_changed?
    return false if new_record? || !@keyframes_json

    cache_key = "presentation_data_changed_#{id}"
    if Presentation.changed_cache_enabled
      data_changed = Rails.cache.read cache_key
    else
      data_changed = nil
    end

    if data_changed.nil?
      # Fetch data again and compare the result

      old_json = @keyframes_json
      new_json = duplicate_keyframes.to_json
      data_changed = old_json != new_json

      # Cache forever, the cache needs to the purged after
      # a data update anyway to get fresh DataValue/IndicatorValue.
      if Presentation.changed_cache_enabled
        Rails.cache.write cache_key, data_changed
      end
    end

    data_changed
  end

  def save_from_scratch
    self.keyframes = duplicate_keyframes
    save
  end

  private

  # Manually serializes the keyframe and saves the original array
  def serialize_keyframes
    @keyframes_array = keyframes
    @keyframes_json = keyframes.to_json
    # Overwrite the attribute temporarily
    self.keyframes = @keyframes_json
  end

  # Restores the keyframes array after serialization
  def restore_keyframes
    self.keyframes = @keyframes_array
  end

  # Manually deserializes the keyframe and saves the original JSON for later
  # *_before_type_cast cannot be used, see
  # https://github.com/rails/rails/issues/15046
  def deserialize_keyframes
    @keyframes_json = keyframes
    raw_keyframes = JSON.parse(
      @keyframes_json, symbolize_names: true, create_additions: false
    )
    create_keyframes(raw_keyframes)
  end

  def clean_renderer_cache
    PresentationRenderer.new(self).clear!
  end

  # Returns a duplicate of the keyframes with fresh data
  def duplicate_keyframes
    keyframes.map do |keyframe|
      keyframe = keyframe.dup
      keyframe.calculate_data!
      keyframe
    end
  end

end
