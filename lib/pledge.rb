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

      if attrs['last_charge_status'] == 'Paid' && !attrs['last_charge_date'].nil?
        last_charge_date = Time.iso8601(attrs['last_charge_date'])
        expiration_date = last_charge_date + attrs['pledge_cadence'].months

        if expiration_date > Time.current
          user = User.joins(:_custom_fields).find_by(user_custom_fields: { name: 'patreon_id', value: patron_id })

          unless user.nil?
            Expiration.set_expiration(user_id: user.id, expiration: expiration_date.iso8601)
          end
        end
      end

      Patreon.set("pledges", all.except(patron_id))
      Decline.set(Decline.all.except(patron_id))
      Patreon.set("users", Patreon::Patron.all.except(patron_id))
      Patreon.set("reward-users", reward_users)
    end

    def self.pull!(uris)
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

        new_reward_users.each do |reward_id, patron_ids|
          patron_ids.each do |patron_id|
            user = User.joins(:_custom_fields).find_by(user_custom_fields: { name: 'patreon_id', value: patron_id })

            unless user.nil?
              Expiration.clear_expiration(user_id: user.id)
            end
          end
        end

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
      pledges, declines, reward_users, users = {}, {}, {}, {}

      if pledge_data && pledge_data["data"].present?
        pledge_data['data'] = [pledge_data['data']] unless pledge_data['data'].kind_of?(Array)

        # get pledges info
        pledge_data['data'].each do |entry|
          if entry['type'] == 'pledge'
            patron_id = entry['relationships']['patron']['data']['id']
            attrs = entry['attributes']

            (reward_users[entry['relationships']['reward']['data']['id']] ||= []) << patron_id unless entry['relationships']['reward']['data'].nil?
            pledges[patron_id] = attrs['amount_cents']
            declines[patron_id] = attrs['declined_since'] if attrs['declined_since'].present?
          elsif entry['type'] == 'member'
            patron_id = entry['relationships']['user']['data']['id']
            attrs = entry['attributes']

            currently_entitled_tiers = entry['relationships']['currently_entitled_tiers'] || {}
            (currently_entitled_tiers['data'] || []).each do |tier|
              (reward_users[tier['id']] ||= []) << patron_id
            end
            pledges[patron_id] = attrs['pledge_amount_cents']
            declines[patron_id] = attrs['last_charge_date'] if attrs['last_charge_status'] == "Declined"
          end
        end

        # get user list too
        pledge_data['included'].each do |entry|
          case entry['type']
          when 'user'
            if entry['attributes']['email'].present?
              users[entry['id']] = entry['attributes']['email'].downcase
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

    class Expiration
      KEY = "expirations".freeze

      def self.all
        Patreon.get(KEY) || {}
      end

      def self.clear_expiration(user_id:)
        expirations = self.all
        expirations.delete(user_id.to_s)
        Patreon.set(KEY, expirations)
      end

      def self.get_expiration(user_id:)
        self.all[user_id.to_s]
      end

      def self.is_expired?(user_id:)
        expiration = self.get_expiration(user_id: user_id)
        expiration.nil? || Time.current >= expiration
      end

      def self.set_expiration(user_id:, expiration:)
        expirations = self.all
        expirations[user_id.to_s] = expiration
        Patreon.set(KEY, expirations)
      end
    end
  end
end
