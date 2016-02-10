module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class Acquiro < Gateway

      URL = 'https://acquiropay.com'

      RESPONSE_CODE_MESSAGES = {
        "100" => "Transaction was Approved",
        "200" => "Transaction was Declined by Processor"
      }

      APPROVED, DECLINED = 'ok', 'ko'

      TRANSACTIONS = {
        void: 'void',
        credit: 'credit',
        refund: 'refund'
      }

      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]
      self.homepage_url = 'client.acquiropay.com'
      # MID = 19
      #Username: slimhealth
      #Merchant: Logigl, LLC
      #Password: SudhXexjxS
      self.display_name = 'Acquiro'
      self.abbreviation = 'ACQ'

    	def initialize(options = {})
        requires!(options, :login, :password)
        @options = options
        super
    	end

      def payment_url(options = {})
        customer    = options[:customer]
        merchant    = options[:merchant]
        order       = options[:order]
        return_url  = options[:return_url]
        uri = URI.parse(return_url)
        protocol = uri.port == 443 ? 'https://' : 'http://'
        cb_url = "#{protocol+uri.host}/payment_response/Acquiro"
        ok_url = "#{protocol+uri.host}/payment_response/Acquiro/redirect/ok"
        broken_url = "#{protocol+uri.host}/off_site_error/Acquiro"

        request = ActiveSupport::OrderedHash.new
        request['product_id']   = merchant.custom_1
        request['product_name'] = '' # optional
        request['amount']       = order.total
        request['cf']           = order.id # Custom Field. Any merchant-defined information that backs to the Merchant with Callback.
        request['cf2']          = merchant.id
        request['cf3']          = ''
        request['first_name']   = customer.first_name
        request['last_name']    = customer.last_name
        request['zip']          = customer.postal_code
        request['address']      = customer.address
        request['city']         = customer.city
        request['region']       = customer.province.name
        #request['country']      = customer.country.code # right now Acquiro has hard coded the country to USA
        request['email']        = customer.email
        request['phone']        = '+1-'+customer.phone
        request['cb_url']       = cb_url
        request['ok_url']       = ok_url + "?return_url=#{CGI.escape(return_url)}&#{request.select {|k,v| k.in?('cf','cf2','cf3')}.to_param}"
        request['token']        = Digest::MD5.hexdigest(merchant.login+merchant.custom_1+order.total.to_s+request['cf'].to_s+request['cf2'].to_s+request['cf3'].to_s+merchant.password)
        #request['ko_url']       = broken_url + "?" + request.to_param + "&problem_url=#{CGI.escape('https://secure.acquiropay.com/?'+request.to_param)}"

        "https://secure.acquiropay.com/?" + request.to_param
      end

      def self.payment_response(params)
        order = Order.find(params[:cf])
        merchant = MerchantAccount.find(params[:cf2])
        if params[:status].downcase.in?(APPROVED, DECLINED)
          payment = order.payments.create!( merchant_account: merchant,
                                            action: 'capture',
                                            account_number: params[:payment_id],
                                            amount: order.total,
                                            currency: order.currency,
                                            description: order.line_items.first.product.name,
                                            customer: order.customer,
                                            first_name: order.customer.first_name,
                                            last_name: order.customer.last_name,
                                            transaction_id: params[:payment_id],
                                            response: params[:status].downcase == APPROVED ? 1 : 2,
                                            reason_code: params[:status].downcase == APPROVED ? 100 : 200
                                          ) if params[:payment_id]
          if params[:status].downcase == APPROVED
            order.customer_campaign.send_receipt
            order.customer_campaign.set_status('success')
            order.update_status('complete')
            order.update_line_item_delivery_types
          elsif params[:status].downcase == DECLINED
            order.customer_campaign.set_status('declined')
            order.update_status('declined')
          end
        else
          raise "Need to handle this status from Acquiro"
        end
        nil
      end

#      def purchase(money, credit_card, options = {})
#        sale_authorization_or_credit_template(:purchase, money, credit_card, options)
#      end
#
#      def authorize(money, credit_card, options = {})
#        sale_authorization_or_credit_template(:authorization, money, credit_card, options)
#      end
#
#      def capture(money, authorization, options = {})
#        capture_void_or_refund_template(:capture, money, authorization, options)
#      end

      def void(authorization, options = {})
        capture_void_or_refund_template(:void, 0, authorization, options)
      end

      def credit(money, authorization, options = {})
        request = {opcode: 1,
          payment_id: authorization,
          token: Digest::MD5.hexdigest("")
        }
        "https://gateway.acquiropay.com/?" + request.to_param
      end

      private

      def sale_authorization_or_credit_template(trx_type, money, credit_card, options = {})
        add_custom_product_id(options)

        post = VerifiPostData.new
        add_security_key_data(post, options, money)
        post.merge!({processor_id: options[:custom_1]})
        commit(trx_type, money, post)
      end

      def capture_void_or_refund_template(trx_type, money, authorization, options)
        add_custom_product_id(options)

        post = VerifiPostData.new
        post[:transactionid] = authorization

        commit(trx_type, money, post)
      end

      def expdate(credit_card)
        year  = sprintf("%.4i", credit_card.year)
        month = sprintf("%.2i", credit_card.month)

        "#{month}#{year[-2..-1]}"
      end

      def add_security_key_data(post, options, money)
        # MD5(username|password|orderid|amount|time)
        now = Time.now.to_i.to_s
        md5 = Digest::MD5.new
        md5 << @options[:login].to_s + "|"
        md5 << @options[:password].to_s + "|"
        md5 << options[:order_id].to_s + "|"
        md5 << amount(money).to_s + "|"
        md5 << now
        post[:key]  = md5.hexdigest
        post[:time] = now
      end

      def commit(trx_type, money, post)
        post[:amount] = amount(money)
        #post.merge!({dup_seconds: 0}) # now you will never get the Duplicate Transaction response

        gateway_request = post_data(trx_type, post)
        raw_response = ssl_post(URL, gateway_request)
        response = parse( raw_response )

        Response.new(response[:response].to_i == SUCCESS, message_from(response), response,
          test: test?,
          authorization: response[:transactionid],
          avs_result: { code: response[:avsresponse] },
          cvv_result: response[:cvvresponse],

          gateway_request: "#{URL}#{gateway_request}",
          gateway_response: raw_response,
          standard_response: response[:response],
          gateway_reason_code: response[:response_code],
          transaction_id: response[:transactionid],
          gateway_message: response[:response_code_message]
        )
      end

      def message_from(response)
        #response[:responsetext] ? response[:responsetext] : response[:response_code_message]
        response[:responsetext]
      end

      def parse(body)
        results = {}
        CGI.parse(body).each { |key, value| results[key.intern] = value[0] }
        results[:response_code_message] = RESPONSE_CODE_MESSAGES[results[:response_code]] if results[:response_code]
        results
      end

      def post_data(trx_type, post)
        if @options[:product_id]
          post[:company_id]   = @options[:login]
          post[:company_key]  = @options[:password]
          post[:product_id]   = @options[:product_id]
        else
          post[:username] = @options[:login]
          post[:password] = @options[:password]
        end
        post[:type] = TRANSACTIONS[trx_type]

        post.to_s
      end

      def add_custom_product_id(options)
        @options[:product_id] = options[:custom_2] unless options[:custom_2].blank?
      end
    end
  end
end
