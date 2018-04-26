# this file was originaly copied from paypal_express.rb
# It is intended to change all of the methods to use the PayPal REST API and PayPal-Ruby-SDK gem
# https://github.com/paypal/PayPal-Ruby-SDK
# It has a long way to go

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaypalExpressRestGateway < Gateway
      require 'paypal-sdk-rest'
      # include PayPal::SDK::REST

      NON_STANDARD_LOCALE_CODES = {
        'DK' => 'da_DK',
        'IL' => 'he_IL',
        'ID' => 'id_ID',
        'JP' => 'jp_JP',
        'NO' => 'no_NO',
        'BR' => 'pt_BR',
        'RU' => 'ru_RU',
        'SE' => 'sv_SE',
        'TH' => 'th_TH',
        'TR' => 'tr_TR',
        'CN' => 'zh_CN',
        'HK' => 'zh_HK',
        'TW' => 'zh_TW'
      }

      self.supported_countries = %w(AT AU BE BR CA CH DE DK ES FI FR GB HK IE IT JP LU MX NL NO NZ PT SE SG US)
      self.homepage_url = 'https://developer.paypal.com/docs/api/'
      self.display_name = 'PayPal Express'
      self.abbreviation = 'PP Exp'

      def initialize(options = {})
        requires!(options, :login, :password)
        paypal_rest_set_config(options)
        super
      end

      def refund(money, transaction_id, options = {})
        # money is an integer
        # use options[:amount_as_string] to get the correct format for the currency
        sale = PayPal::SDK::REST::Sale.find(transaction_id)
        refund_amount = {amount: {
                          total:    options[:amount_as_string],
                          currency: options[:currency]
                        }}
        refund = sale.refund_request(refund_amount)
        response_from_refund(refund)
      end

      def suspend_recurring(agreement_id)
        agreement = PayPal::SDK::REST::Agreement.find(agreement_id)
        agreement.suspend(note: "Suspending the agreement")
      end

      def activate_recurring(agreement_id)
        agreement = PayPal::SDK::REST::Agreement.find(agreement_id)
        agreement.re_activate(note: "Re-activating the agreement")
      end

      def cancel_recurring(agreement_id)
        agreement = PayPal::SDK::REST::Agreement.find(agreement_id)
        agreement.cancel(note: "Canceling the agreement")
      end

      def agreement_next_bill_date(agreement_id)
        agreement = PayPal::SDK::REST::Agreement.find(agreement_id)
        next_bill_date = Time.parse(agreement.agreement_details.next_billing_date) rescue nil
        next_bill_date
      end

      private

        def paypal_rest_set_config(options)
          PayPal::SDK::REST.set_config(
            client_id:     options[:login],
            client_secret: options[:password],
            mode: options[:test_env] ? 'sandbox' : 'live'
          )
        end

        def response_from_refund(refund)
          refund_hash = refund.to_hash
          if refund.success?
            status = refund.state
            response = 1
            reason_code = '100'
            display_message = 'Approved'
          else
            status = refund.error.name
            response = 2
            reason_code = '200'
            display_message = refund.error.message
          end
          Response.new(refund.success?, display_message, refund_hash,
            test: test?,
            gateway_response:     refund_hash,
            standard_response:    response,
            gateway_reason_code:  reason_code,
            transaction_id:       refund.id,
            gateway_message:      status,
            authorization:        refund.id
          )
        end

    end
  end
end
