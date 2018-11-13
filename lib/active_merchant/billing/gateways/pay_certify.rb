module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PayCertifyGateway < Gateway
      # documentation: https://paycertify.github.io/help-center/gateway/

      self.live_url = 'https://gateway-api.paycertify.com/api/transactions'
      self.test_url = 'https://qa-gateway-api.paycertify.com/api/transactions'

      self.supported_countries = ['US']
 #     self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club, :maestro]
      self.supported_cardtypes = [:visa, :master, :american_express]
      self.homepage_url = 'https://paycertify.com'
      self.default_currency = 'USD'
      self.display_name = 'PayCertify'
      self.abbreviation = 'PayCertify'

      def initialize(options = {})
        requires!(options, :login)
        @access_token = options[:login]
        super(options)
      end

      def purchase(amount, payment_method, options={})
        post = {}
        add_invoice(post, amount, options)
        add_payment_method(post, payment_method)
        add_customer_data(post, options)

        commit(:purchase, post)
      end

      def authorize(amount, payment_method, options={})
        post = {}
        add_invoice(post, amount, options)
        add_payment_method(post, payment_method)
        add_customer_data(post, options)

        commit(:authorize, post)
      end

      def capture(amount, authorization, options={})
        post = {transaction_id: authorization}
        add_amount(post, amount)

        commit(:capture, post)
      end

      def void(authorization, options={})
        post = {transaction_id: authorization}
        add_amount(post, amount)

        commit(:void, post)
      end

      def refund(amount, authorization, options={})
        post = {transaction_id: authorization}
        add_amount(post, amount)

        commit(:refund, post)
      end

      private

        def add_amount(post, money)
          post[:amount] = amount(money)
        end

        def add_invoice(post, money, options)
          add_amount(post, money)
          post[:processor_id] = options[:custom_1] # optional
          post[:merchant_transaction_id] = options[:order_id].presence || options[:payment_id]
          post[:currency] = options[:currency] || currency(money)
          post[:dynamic_descriptor] = options[:statement_description]
          # Our dynamic descriptor implementation uses a pipe element | to separate the name from the contact info (which may be the city, phone or website).
          # So for example, a dynamic descriptor passed as MYBUSINESSINC|123-1231234 will be interpreted at processor level as name=MYBUSINESSINC and contact info=123-1231234.
        end

        def add_payment_method(post, payment_method)
          post[:card_number]  = payment_method.number
          post[:card_cvv]     = payment_method.verification_value
          post[:card_expiry_year]   = format(payment_method.year, :four_digits)
          post[:card_expiry_month]  = format(payment_method.month, :two_digits)
        end

        def add_customer_data(post, options)
          post[:email] = options[:email]
          if address = options[:billing_address] || options[:address]
            post[:first_name] = options[:first_name]
            post[:last_name]  = options[:last_name]
            post[:ip_address] = options[:ip]
            post[:street_address_1] = address[:address1]
            post[:street_address_2] = address[:address2]
            post[:city]     = address[:city]
            post[:state]    = address[:state_code]
            post[:country]  = address[:country_code]
            post[:zip]      = address[:zip]
            post[:mobile_phone] = address[:phone]
            if calling_code = address[:country_calling_code].presence
              phone_prefix = '+' + calling_code
              if post[:mobile_phone].present? && !post[:mobile_phone].starts_with?(phone_prefix)
                post[:mobile_phone] = phone_prefix + post[:mobile_phone]
              end
            end
          end
        end

        ACTIONS = {
          purchase:   "sale",
          authorize:  "auth",
          capture:    "capture",
          void:       "void",
          refund:     "refund"
        }

        def commit(action, post)
          begin
            raw_response = ssl_post(url(action, post[:transaction_id]), post.to_param, headers)
            response = parse(raw_response)
          rescue ResponseError => e
            raise unless(e.response.code.to_s =~ /4\d\d/)
            response = parse(e.response.body)
          end
          # ActiveMerchant.logger.debug "============================="
          # ActiveMerchant.logger.debug raw_response.inspect
          # ActiveMerchant.logger.debug "============================="
          # ActiveMerchant.logger.debug response.inspect
          # ActiveMerchant.logger.debug "============================="
          # ActiveMerchant.logger.debug "Done with ActiveMerchant logging"

          transaction = response[:transaction] || {}
          error       = response[:error] || {}
          event       = event_from_transaction(transaction, action)
          success     = event[:success].presence || false

          Response.new(
            success,
            error.any? ? error_message_as_string(error) : event[:processor_message],
            response,
            {
              test:               test?,
              authorization:      transaction[:id],
              avs_result:         { code: event[:avs_response] },
              cvv_result:         nil,
              error_code:         error[:status],
            }.merge(standard_response_values(success, response, action))
          )
        rescue JSON::ParserError
          unparsable_response(raw_response)
        end

        def standard_response_values(success, response, action)
          transaction = response[:transaction] || {}
          error       = response[:error] || {}
          event       = event_from_transaction(transaction, action)
          transaction_id = transaction[:id]

          if success
            standard_response = 1
            gateway_reason_code = event[:processor_code]
            gateway_message     = event[:processor_message]
            gateway_display_message = 'Approved'
          else
            gateway_reason_code = event[:processor_code] ||
                                  error[:status]
            gateway_message     = event[:processor_message] ||
                                  error_message_as_string(error)
            gateway_display_message = gateway_message
            standard_response = 2
            standard_response = 3 if error.any?
          end

          {
            gateway_request:      nil,
            gateway_response:     response,
            standard_response:    standard_response,
            gateway_reason_code:  gateway_reason_code,
            transaction_id:       transaction_id,
            gateway_message:      gateway_message.to_s.strip,
            gateway_display_message: gateway_display_message.to_s.strip
          }
        end

        def url(action, transaction_id)
          temp_url = (test? ? test_url : live_url)
          temp_url += "/#{transaction_id}" if transaction_id.present?
          temp_url + "/" + ACTIONS[action]
        end

        def parse(response)
          JSON.parse(response).with_indifferent_access
        end

        def unparsable_response(raw_response)
          message = "Unparsable response received from #{display_name}. Please contact #{display_name} if you continue to receive this message."
          message += " (The raw response returned by the API was #{raw_response.inspect})"
          return Response.new(false, message)
        end

        def event_from_transaction(transaction, action)
          return {} if transaction.blank?
          transaction[:events].select { |t| t[:event_type] == ACTIONS[action] }.last
        end

        def error_message_as_string(error)
          error[:message].map { |e| e.join(': ') }.join(' ')
        end

        def headers
          {
            "Authorization" => "Bearer #{@access_token}"
          }
        end

    end
  end
end

