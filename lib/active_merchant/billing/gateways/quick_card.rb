module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class QuickCard < Gateway
      # documentation: https://www.dropbox.com/sh/ho6zcxa30osxau1/AAAdqoZkzp9R7cCB_lc-So2qa?dl=0

      self.test_url = 'https://quickcard.herokuapp.com'
      self.live_url = 'https://api.quickcard.me'

      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club, :maestro]
      self.homepage_url = 'https://fdf.transactiongateway.com'
      self.default_currency = 'USD'
      self.display_name = 'QuickCard'
      self.abbreviation = 'QuickCard'

      def initialize(options = {})
        requires!(options, :login, :password)
        super
      end

      def purchase(amount, payment_method, options={})
        post = {location_id: options[:custom_1]}
        add_amount(post, amount)
        add_payment_method(post, payment_method)
        add_customer_data(post, options)

        commit(post, "/api/registrations/virtual_transaction")
      end

      def refund(amount, authorization, options={})
        post = {transact_id: authorization,
                partial_amount: amount(amount)
               }
        commit(post, "/api/wallets/refund_money")
      end


      private

        def add_amount(post, money)
          post[:amount] = amount(money)
        end

        def add_payment_method(post, payment_method)
          post[:card_number]  = payment_method.number
          post[:card_cvv]     = payment_method.verification_value if payment_method.verification_value.present?
          post[:exp_date]     = format(payment_method.month, :two_digits) + format(payment_method.year, :two_digits)
        end

        def add_customer_data(post, options)
          post[:email] = options[:email]
          if address = options[:billing_address] || options[:address]
            post[:first_name] = options[:first_name]
            post[:last_name]  = options[:last_name]
            post[:name]       = [options[:first_name], options[:last_name]].join(' ')
            post[:phone_number] = address[:phone]
          end
        end

        def authenticate(post)
          json = ssl_post(url("/oauth/token/retrieve"), {client_id: @options[:login], client_secret: @options[:password]}.to_param)
          response = parse(json)
          post[:auth_token] = response[:access_token]
        end

        def url(resource)
          (test? ? self.test_url : self.live_url) + resource
        end

        def commit(post, path)
          authenticate(post)
          raw_response = ssl_post(url(path), post.to_param)
          response = parse(raw_response)

          ActiveMerchant.logger.debug "============================="
          ActiveMerchant.logger.debug raw_response.inspect
          ActiveMerchant.logger.debug "============================="
          ActiveMerchant.logger.debug response.inspect
          ActiveMerchant.logger.debug "============================="
          ActiveMerchant.logger.debug "Done with ActiveMerchant logging"

          success = response[:success] && response[:status] == 'approved'
          # the actual response message is super verbose. Looks something like:
          # Dear Mike Ball, your card (x-4242) has been successfully charged 5.00 USD for your purchase from SandBox Integration. This transaction will appear on your statement as Abd_GW_Desc. For questions or assistance, please contact (619) 631-3253.
          # Use a much more succinct message instead
          response[:message] = 'Successfully Charged' if response[:message].to_s.include?('has been successfully charged')

          Response.new(
            success,
            response[:message],
            response,
            {
              test:               test?,
              authorization:      response[:transaction_id],
            }.merge(standard_response_values(success, response))
          )
        rescue JSON::ParserError
          unparsable_response(raw_response)
        end

        def standard_response_values(success, response)
          standard_response = success ? 1 : 2
          transaction_id = response[:transaction_id]
          gateway_reason_code = standard_response
          gateway_message     = response[:message].to_s.strip

          {
            gateway_request:      nil,
            gateway_response:     response,
            standard_response:    standard_response,
            gateway_reason_code:  gateway_reason_code,
            transaction_id:       transaction_id,
            gateway_message:      gateway_message,
            gateway_display_message: gateway_message,
          }
        end

        def parse(response)
          JSON.parse(response).with_indifferent_access
        end

        def unparsable_response(raw_response)
          message = "Unparsable response received from #{display_name}. Please contact #{display_name} if you continue to receive this message."
          message += " (The raw response returned by the API was #{raw_response.inspect})"
          return Response.new(false, message)
        end

    end
  end
end
