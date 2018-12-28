module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class TransactionGateway < Gateway
      # documentation: https://fdf.transactiongateway.com/merchants/resources/integration/integration_portal.php#methodology

      # Other Gateways inherit from this one, like FirstDirectFinancial

      def initialize(options = {})
        requires!(options, :login)
        @username = options[:login]
        @password = options[:password].presence # not required
        # The API uses either username and password
        # OR
        # a security_key
        # If the password is blank, it assumes the username is the security_key
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
        post = {transactionid: authorization}
        add_amount(post, amount)

        commit(:capture, post)
      end

      def void(authorization, options={})
        post = {transactionid: authorization}
        add_amount(post, amount)

        commit(:void, post)
      end

      def refund(amount, authorization, options={})
        post = {transactionid: authorization}
        add_amount(post, amount)

        commit(:refund, post)
      end

      def credit(amount, payment_method, options={})
        #todo
        commit(:credit, post)
      end

      def validate(payment_method)
        # "Account Verification" on the cardholder's credit card without actually doing an authorization.

      end

      def update(options)
        # update previous transactions with specific order information, such as a tracking number and shipping carrier
      end


      private

        def add_amount(post, money)
          post[:amount] = amount(money)
        end

        def add_invoice(post, money, options)
          add_amount(post, money)
          post[:processor_id] = options[:custom_1] # optional
          post[:orderid] = options[:order_id].presence || options[:payment_id]
          post[:currency] = options[:currency] || currency(money)
          post[:descriptor] = options[:statement_description]
        end

        def add_payment_method(post, payment_method)
          post[:ccnumber] = payment_method.number
          post[:cvv]      = payment_method.verification_value if payment_method.verification_value.present?
          post[:ccexp]    = format(payment_method.month, :two_digits) + format(payment_method.year, :two_digits)
        end

        def add_customer_data(post, options)
          post[:email] = options[:email]
          if address = options[:billing_address] || options[:address]
            post[:first_name] = options[:first_name]
            post[:last_name]  = options[:last_name]
            post[:ipaddress]  = options[:ip]
            post[:company]  = address[:company]
            post[:address1] = address[:address1]
            post[:address2] = address[:address2]
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

        def authenticate(post)
          if @password.blank?
            # assume the username is the security_key
            post[:security_key] = @username
          else
            post[:username] = @username
            post[:password] = @password
          end
        end

        def commit(action, post)
          authenticate(post)
          post[:type] = ACTIONS[action] || action
          raw_response = ssl_post(live_url, post.to_param)
          response = parse(raw_response)

          ActiveMerchant.logger.debug "============================="
          ActiveMerchant.logger.debug raw_response.inspect
          ActiveMerchant.logger.debug "============================="
          ActiveMerchant.logger.debug response.inspect
          ActiveMerchant.logger.debug "============================="
          ActiveMerchant.logger.debug "Done with ActiveMerchant logging"

          success     = response[:response] == '1'

          Response.new(
            success,
            response[:responsetext],
            response,
            {
              test:               test?,
              authorization:      response[:authcode],
              avs_result:         { code: response[:avsresponse] },
              cvv_result:         response[:cvvresponse],
              emv_authorization:  response[:emv_auth_response_data],
              error_code:         (!success ? response[:response_code] : nil),
            }.merge(standard_response_values(success, response, action))
          )
        rescue JSON::ParserError
          unparsable_response(raw_response)
        end

        def standard_response_values(success, response, action)
          standard_response = response[:response].to_i
          transaction_id = response[:transactionid]
          gateway_reason_code = response[:response_code]
          gateway_message     = response[:responsetext].to_s.strip

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
          CGI.parse(response).transform_values(&:first).with_indifferent_access
        end

        def unparsable_response(raw_response)
          message = "Unparsable response received from #{display_name}. Please contact #{display_name} if you continue to receive this message."
          message += " (The raw response returned by the API was #{raw_response.inspect})"
          return Response.new(false, message)
        end

    end
  end
end
