# frozen_string_literal: true

module ::Patreon
  class Pledge

    def self.create!(pledge_data)
      save!([pledge_data], true)
    end

    def self.update!(pledge_data)
      delete!(pledge_data)
      create!(pledge_data)
    end

    def self.delete!(pledge_data)
      entry = pledge_data["data"]
      attrs = entry['attributes']
      rel = entry['relationships']
      reward_users = Patreon::RewardUser.all

      if entry["type"] == 'pledge'
        patron_id = rel['patron']['data']['id']
        reward_id = rel['reward']['data']['id'] unless rel['reward']['data'].blank?

        reward_users[reward_id].reject! { |i| i == patron_id } if reward_id.present?
      elsif entry["type"] == 'member'
        patron_id = rel['user']['data']['id']

        (rel['currently_entitled_tiers']['data'] || []).each do |tier|
          (reward_users[tier['id']] || []).reject! { |i| i == patron_id }
        end
      end

      Patreon.set("pledges", all.except(patron_id))
      Decline.set(Decline.all.except(patron_id))
      Patreon.set("users", Patreon::Patron.all.except(patron_id))
      Patreon.set("reward-users", reward_users)
    end

    def self.pull!(campaign_ids)
      uris = campaign_ids.map { |id| Patreon::Api.build_members_uri(id) }
      pledges_data = []

      uris.each do |uri|
        pledge_data = ::Patreon::Api.get(uri)

        # get next page if necessary and add to the current loop
        if pledge_data['links'] && pledge_data['links']['next']
          next_page_uri = pledge_data['links']['next']
          uris << next_page_uri if next_page_uri.present?
        end

        pledges_data << pledge_data if pledge_data.present?
        raise ArgumentError.new("broken response") unless pledge_data.present? and not pledge_data.key?(:error)
      end

      save!(pledges_data)
    end

    def self.save!(pledges_data, is_append = false)
      pledges = is_append ? all : {}
      reward_users = is_append ? Patreon::RewardUser.all : {}
      users = is_append ? Patreon::Patron.all : {}
      declines = is_append ? Decline.all : {}

      pledges_data.each do |pledge_data|
        new_pledges, new_declines, new_reward_users, new_users = extract(pledge_data)

        pledges.merge!(new_pledges)
        declines.merge!(new_declines)
        users.merge!(new_users)

        Patreon::Reward.all.keys.each do |key|
          reward_users[key] = (reward_users[key] || []) + (new_reward_users[key] || [])
        end
      end

      reward_users['0'] = pledges.keys

      Patreon.set('pledges', pledges)
      Decline.set(declines)
      Patreon.set('reward-users', reward_users)
      Patreon.set('users', users)
    end

    def self.extract(pledge_data)
      pledges, declines, users = {}, {}, {}, {}
      reward_users = Hash.new { |h, k| h[k] = [] }

      if pledge_data && pledge_data["data"].present?
        pledge_data['data'] = [pledge_data['data']] unless pledge_data['data'].kind_of?(Array)

        # get pledges info
        pledge_data['data'].each do |entry|
          next if entry['relationships']['currently_entitled_tiers']['data'].empty?

          if entry['type'] == 'member'
            patron_id = entry['relationships']['user']['data']['id']
            attrs = entry['attributes']

            entry['relationships']['currently_entitled_tiers']['data'].each do |tier|
              reward_users[tier['id']] << patron_id
            end
            pledges[patron_id] = attrs['currently_entitled_amount_cents']
            declines[patron_id] = attrs['last_charge_date'] if attrs['last_charge_status'] == "Declined"

            if attrs['email'].present?
              users[patron_id] = attrs['email'].downcase
            end
          end
        end
      end

      [pledges, declines, reward_users, users]
    end

    def self.all
      Patreon.get('pledges') || {}
    end

    def self.get_patreon_id(pledge_data)
      data = pledge_data['data']
      key = data['type'] == "member" ? "user" : "patron"
      data['relationships'][key]['data']['id']
    end

    class Decline

      KEY = "pledge-declines".freeze

      def self.all
        Patreon.get(KEY) || {}
      end

      def self.set(value)
        Patreon.set(KEY, value)
      end

    end
  end
end
