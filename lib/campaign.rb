# frozen_string_literal: true

require 'json'

module ::Patreon
  class Campaign

    def self.update!
      rewards = {}
      campaign_ids = []
      campaign_tiers = []

      response = ::Patreon::Api.campaign_data

      return false if response.blank? || response['data'].blank?

      response['data'].map do |campaign|
        campaign_ids << campaign['id']

        campaign['relationships']['tiers']['data'].each do |entry|
          campaign_tiers << entry['id']
        end
      end

      response['included'].each do |entry|
        id = entry['id']
        if entry['type'] == 'tier' && campaign_tiers.include?(id)
          rewards[id] = entry['attributes']
          rewards[id]['id'] = id
        end
      end

      # Special catch all patrons virtual reward
      rewards['0'] ||= {}
      rewards['0']['title'] = 'All Patrons'
      rewards['0']['amount_cents'] = 0

      Patreon.set('rewards', rewards)

      Patreon::Pledge.pull!(campaign_ids)

      # Sets all patrons to the seed group by default on first run
      filters = Patreon.get('filters')
      Patreon::Seed.seed_content! if filters.blank?

      true
    end

  end
end
