require 'rexml/document'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class ChargebackGuardian < Gateway
      class VerifiPostData < PostData
        # Fields that will be sent even if they are blank
        self.required_fields = [ :amount, :type, :ccnumber, :ccexp, :firstname, :lastname,
          :company, :address1, :address2, :city, :state, :zip, :country, :phone ]
      end

      URL = 'https://www.cbggatewaysecure.com/Controller/client/scrubsEngineCurl.php'

      # default credentials for production
      # these will be applied if the option[:login] matches /default/i
      # gateway URL: https://secure.chargebackguardiangateway.com/merchants/login.php
      # default login to the gateway: logiql2008
      # default password to the gateway: beachM0n3y1
      if ENV['RAILS_ENV'] == 'production'
        COMPANY_ID = 'ZaKjZGPzdxhLVgmZhjHw'
        COMPANY_KEY = 'sZUxYi5DJyzWCA7AXoDw'
        PRODUCT_ID = 96
      else
        COMPANY_ID = 'S3zNgXHWhWb7yFbNtL3C'
        COMPANY_KEY = 'DZ7XW4T3PWGL8hvSvZQA'
        PRODUCT_ID = 4 # or 5
      end

      RESPONSE_CODE_MESSAGES = {
        "100" => "Transaction was Approved",
        "200" => "Transaction was Declined by Processor",
        "201" => "Do Not Honor",
        "202" => "Insufficient Funds",
        "203" => "Over Limit",
        "204" => "Transaction not allowed",
        "220" => "Incorrect payment Data",
        "221" => "No Such Card Issuer",
        "222" => "No Card Number on file with Issuer",
        "223" => "Expired Card",
        "224" => "Invalid Expiration Date",
        "225" => "Invalid Card Security Code",
        "240" => "Call Issuer for Further Information",
        "250" => "Pick Up Card",
        "251" => "Lost Card",
        "252" => "Stolen Card",
        "253" => "Fraudulent Card",
        "260" => "Declined With further Instructions Available (see response text)",
        "261" => "Declined - Stop All Recurring Payments",
        "262" => "Declined - Stop this Recurring Program",
        "263" => "Declined - Update Cardholder Data Available",
        "264" => "Declined - Retry in a few days",
        "300" => "Transaction was Rejected by Gateway",
        "400" => "Transaction Error Returned by Processor",
        "410" => "Invalid Merchant Configuration",
        "411" => "Merchant Account is Inactive",
        "420" => "Communication Error",
        "421" => "Communication Error with Issuer",
        "430" => "Duplicate Transaction at Processor",
        "440" => "Processor Format Error",
        "441" => "Invalid Transaction Information",
        "460" => "Processor Feature Not Available",
        "461" => "Unsupported Card Type"
      }

      SUCCESS = 1

      TRANSACTIONS = {
        authorization: 'auth',
        purchase: 'sale',
        capture: 'capture',
        validate: 'validate',
        void: 'void',
        credit: 'credit',
        refund: 'refund',
        update: 'update'
      }

      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]
      self.homepage_url = 'www.chargebackguardian.com/'
      self.display_name = 'Chargeback Guardian'
      self.abbreviation = 'CG'

    	def initialize(options = {})
        requires!(options, :login, :password)
        @options = options
        if @options[:login].blank? or @options[:login].match(/default/i)
          @options[:login]      = COMPANY_ID
          @options[:password]   = COMPANY_KEY
          @options[:product_id] = PRODUCT_ID if @options[:product_id].blank?
        end
        super
    	end

      def purchase(money, credit_card, options = {})
        if money == 0
          validate(credit_card, options)
        else
          sale_authorization_or_credit_template(:purchase, money, credit_card, options)
        end
      end

      def authorize(money, credit_card, options = {})
        if money == 0
          validate(credit_card, options)
        else
          sale_authorization_or_credit_template(:authorization, money, credit_card, options)
        end
      end

      def validate(credit_card, options = {})
        sale_authorization_or_credit_template(:validate, nil, credit_card, options)
      end

      def capture(money, transaction_id, options = {})
        capture_void_refund_or_update_template(:capture, money, transaction_id, options)
      end

      def void(transaction_id, options = {})
        capture_void_refund_or_update_template(:void, 0, transaction_id, options)
      end

      def credit(money, transaction_id, options = {})
        unless transaction_id.nil?
          capture_void_refund_or_update_template(:refund, money, transaction_id, options)
        else
          credit_card = CreditCard.new( number: options[:card_number],
                                        month: options[:expiration_month],
                                        year: options[:expiration_year],
                                        first_name: options[:first_name],
                                        last_name: options[:last_name])
          sale_authorization_or_credit_template(:credit, money, credit_card, options)
        end
      end

      def update(transaction_id, options)
        return if options.empty?

        capture_void_refund_or_update_template(:update, nil, transaction_id, options)
      end

      private

      def sale_authorization_or_credit_template(trx_type, money, credit_card, options = {})
        add_custom_product_id(options)

        post = VerifiPostData.new
        add_security_key_data(post, options, money)
        add_credit_card(post, credit_card)
        add_addresses(post, options)
        add_customer_data(post, options)
        add_invoice_data(post, options)
        add_optional_data(post, options)
        post.merge!({processor_id: options[:custom_1]})
        post.merge!({billing_method: 'recurring'})        if options[:billing_method] == 'recurring'
        post.merge!({currency: options[:currency]}) if options[:currency]
        post.merge!(custom_defined_fields(options))
        post.merge!(custom_evoke_fields(options))

        commit(trx_type, money, post)
      end

      def capture_void_refund_or_update_template(trx_type, money, transaction_id, options = {})
        add_custom_product_id(options)

        post = VerifiPostData.new
        post[:transactionid] = transaction_id
        post.merge!(custom_defined_fields(options))
        post.merge!(custom_evoke_fields(options))

        commit(trx_type, money, post)
      end

      def custom_defined_fields(options)
        custom = {}
        custom.merge!({merchant_defined_field_11: options[:description]})  unless options[:description].blank?
        custom.merge!({merchant_defined_field_12: options[:affiliate]})    unless options[:affiliate].blank?
        custom.merge!({merchant_defined_field_13: options[:sub_campaign]}) unless options[:sub_campaign].blank?
        custom.merge!({merchant_defined_field_14: options[:chargeback]})   if options[:chargeback].in? ['yes','no']
        custom.merge!({merchant_defined_field_15: options[:retrieval]})    if options[:retrieval].in? ['yes','no']

        return custom
      end

      def custom_evoke_fields(options)
        evoke = {}
        evoke.merge!({maRECORD: options[:ma_record]})  unless options[:ma_record].blank?
        evoke.merge!({maTRANS: options[:ma_trans]})   unless options[:ma_trans].blank?

        return evoke
      end

      def add_credit_card(post, credit_card)
        post[:ccnumber]  = credit_card.number
        post[:ccexp]     = expdate(credit_card)
        post[:firstname] = credit_card.first_name
        post[:lastname]  = credit_card.last_name
        post[:cvv]       = credit_card.verification_value
      end

      def expdate(credit_card)
        year  = sprintf("%.4i", credit_card.year)
        month = sprintf("%.2i", credit_card.month)

        "#{month}#{year[-2..-1]}"
      end

      def add_addresses(post, options)
        if billing_address = options[:billing_address] || options[:address]
          post[:company]    = billing_address[:company]
          post[:address1]   = billing_address[:address1]
          post[:address2]   = billing_address[:address2]
          post[:city]       = billing_address[:city]
          post[:state]      = billing_address[:state]
          post[:zip]        = billing_address[:zip]
          post[:country]    = Carmen::Country.named(billing_address[:country]).try(:code) || billing_address[:country]
          post[:phone]      = billing_address[:phone]
          post[:fax]        = billing_address[:fax]
        end

        if shipping_address = options[:shipping_address]
          post[:shipping_firstname] = shipping_address[:first_name]
          post[:shipping_lastname]  = shipping_address[:last_name]
          post[:shipping_company]   = shipping_address[:company]
          post[:shipping_address1]  = shipping_address[:address1]
          post[:shipping_address2]  = shipping_address[:address2]
          post[:shipping_city]      = shipping_address[:city]
          post[:shipping_state]     = shipping_address[:state]
          post[:shipping_zip]       = shipping_address[:zip]
          post[:shipping_country]   = Carmen::Country.named(shipping_address[:country]).try(:code) || shipping_address[:country]
          post[:shipping_email]     = shipping_address[:email]
        end
      end

      def add_customer_data(post, options)
        post[:email]     = options[:email]
        post[:ipaddress] = options[:ip]
      end

      def add_invoice_data(post, options)
        post[:orderid]            = options[:order_id]
        post[:ponumber]           = options[:invoice]
        post[:orderdescription]   = options[:description]
        post[:tax]                = options[:tax]
        post[:shipping]           = options[:shipping]
      end

      def add_optional_data(post, options)
        post[:billing_method]     = options[:billing_method]
        post[:website]            = options[:website]
        post[:descriptor]         = options[:descriptor]
        post[:descriptor_phone]   = options[:descriptor_phone]
        post[:cardholder_auth]    = options[:cardholder_auth]
        post[:cavv]               = options[:cavv]
        post[:xid]                = options[:xid]
        post[:customer_receipt]   = options[:customer_receipt]
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
        post[:amount] = amount(money) unless money.nil?
        #post.merge!({dup_seconds: 0}) # now you will never get the Duplicate Transaction response

        gateway_request = post_data(trx_type, post)
        raw_response = ssl_post(URL, gateway_request)
        response = parse( raw_response )

        Response.new(response[:response].to_i == SUCCESS, message_from(response), response,
          test: test?,
          authorization: response[:authcode],
          avs_result: { code: response[:avsresponse] },
          cvv_result: response[:cvvresponse],

          gateway_request: "#{URL}?#{gateway_request}",
          gateway_response: raw_response,
          standard_response: response[:response],
          gateway_reason_code: response[:response_code],
          transaction_id: response[:transactionid],
          gateway_message: response[:response_code_message],
          ma_record: response[:maRECORD],
          ma_trans: response[:maTRANS]
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
        if results[:response].to_i == 6
          if results[:response_code].to_i == 610
            # Prepaid Credit/Debit Card
            results[:response] = 2
          elsif results[:response_code].to_i == 696
            # Network Transmission Error
            results[:response] = 3
          end
        end
        results
      end

      def post_data(trx_type, post)
        post[:company_id]   = @options[:login]
        post[:company_key]  = @options[:password]
        post[:product_id]   = @options[:product_id]
        post[:type]         = TRANSACTIONS[trx_type]

        post.to_s
      end

      def add_custom_product_id(options)
        @options[:product_id] = options[:custom_2] unless options[:custom_2].blank?
      end
    end
  end
end
