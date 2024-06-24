# frozen_string_literal: true

require 'json'
require 'faraday'
require 'faraday/retry'

module ::Patreon

  class InvalidApiResponse < ::StandardError; end

  class Api

    ACCESS_TOKEN_INVALID = "dashboard.patreon.access_token_invalid".freeze
    INVALID_RESPONSE = "patreon.error.invalid_response".freeze

    def self.build_members_uri(campaign_id)
        "/oauth2/v2/campaigns/#{campaign_id}/members?include=currently_entitled_tiers,user&fields[member]=currently_entitled_amount_cents,email,last_charge_date,last_charge_status"
    end

    def self.campaign_data
      get('/oauth2/v2/campaigns?include=tiers&fields[tier]=amount_cents,title&page[count]=100')
    end

    def self.get(uri)
      limiter_hr = RateLimiter.new(nil, "patreon_api_hr", SiteSetting.max_patreon_api_reqs_per_hr, 1.hour)
      limiter_day = RateLimiter.new(nil, "patreon_api_day", SiteSetting.max_patreon_api_reqs_per_day, 1.day)
      AdminDashboardData.clear_problem_message(ACCESS_TOKEN_INVALID) if AdminDashboardData.problem_message_check(ACCESS_TOKEN_INVALID)

      unless limiter_hr.can_perform?
        limiter_hr.performed!
      end

      unless limiter_day.can_perform?
        limiter_day.performed!
      end

      retry_options = {
        max: 4,
        interval: 2,
        interval_randomness: 1,
        backoff_factor: 2,
        retry_statuses: [502, 504, 500, 503],
        exceptions: [
          Errno::ETIMEDOUT, 'Timeout::Error',
          Faraday::TimeoutError, Faraday::RetriableResponse,
          Faraday::ServerError
        ]
      }

      conn = Faraday.new(
        url: 'https://api.patreon.com',
        headers: { 'Authorization' => "Bearer #{SiteSetting.patreon_creator_access_token}" }
      ) do |c|
        c.use Faraday::Response::RaiseError
        c.request :retry, retry_options
      end

      response = conn.get(uri)

      limiter_hr.performed!
      limiter_day.performed!

      case response.status
      when 200
        return JSON.parse response.body
      when 401
        AdminDashboardData.add_problem_message(ACCESS_TOKEN_INVALID, 7.hours)
      else
        e = ::Patreon::InvalidApiResponse.new(response.body.presence || '')
        e.set_backtrace(caller)
        Discourse.warn_exception(e, message: I18n.t(INVALID_RESPONSE), env: { api_uri: uri })
      end

      { error: I18n.t(INVALID_RESPONSE) }
    end

  end
end
