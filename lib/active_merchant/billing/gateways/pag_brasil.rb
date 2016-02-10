# coding: utf-8

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:

    # To test a credit card charge, please use the following CC details:
    # Brand: V
    # Number: 4984123412341234
    # CVV: 123 (any other cvv for a decline)
    # Expiration: 12/19

    # Gateway ReasonCodes (hard coded the following codes)
    # 318 - CreditCard TimeOut (PagBrasil's processor doesn't like this card, tell the customer to use a different card.)

    class PagBrasilGateway < Gateway
      # URL = 'https://www.siliconaction.com/pagbrasil/addorder.mv'
      URL         = 'https://connect.pagbrasil.com/pagbrasil/addorder.mv'
      REFUND_URL  = 'https://connect.pagbrasil.com/pagbrasil/refundorder.mv'
      # REFUND_URL  = 'https://www.siliconaction.com/pagbrasil/refundorder.mv'
      PAYMENT_METHODS = {credit_card: 'C', boleto: 'B'}
      ACCEPTED_CARD_BRANDS = {mastercard: 'M',
                              visa: 'V',
                              diners_club: 'D',
                              american_express: 'A',
                              hipercard: 'H',
                              elo: 'E'
                              }
      SUCCESSFUL_RESPONSES = ["Order processed.","Order queued to be processed.","Refund request received"]

      # Payment status codes are used with the response PagBrasil posts to us
      PAYMENT_STATUS_CODES = {'A' => 'Authorized',
                              'F' => 'Failed',
                              'R' => 'Rejected' # fraud screening denied the transaction for security reasons
                             }
      PAYMENT_SUCCESSFUL_STATUS = 'A'

      # Order status codes are used when actively requesting the order status
      ORDER_SUCCESSFUL_STATUSES = ['PC', 'RP']
      ORDER_DECLINE_STATUSES = ['PF', 'PR']
      ORDER_STATUS_CODES = {'WP' => 'Payment requested but not processed yet',
                            'PC' => 'Payment completed',
                            'PF' => 'Payment failed',
                            'PR' => 'Payment rejected',
                            'RR' => 'Refund requested',
                            'RP' => 'Refund completed'
                           }

      self.supported_countries = ['BR']
      self.supported_cardtypes = [:visa, :master, :american_express, :diners_club, :hipercard, :elo]
      self.homepage_url = 'http://www.pagbrasil.com'
      self.display_name = 'PagBrasil'
      self.abbreviation = 'BRA' #changed from PBR, to mask the name of the gateway for untrusted CS reps

      def initialize(options = {})
        requires!(options, :password)
        @options = options
        super
      end

      def purchase(money, credit_card=nil, options = {})
        post = {}
        verify_installments(money, options) if options[:method] == 'C'
        add_order(post, options)
        add_payment_source(post, credit_card, options)
        add_product_names(post, options)
        add_address(post, options)
        add_customer_data(post, options)

        ActiveRecord::Base.logger.debug "====================== Calling commit"

        commit 'purchase', money, post
      end

      def refund(money, transaction_id, options = {})
        post = {}
        # order, amount_refunded
        refundable_payment =  Payment.joins(:merchant_account).where(transaction_id: transaction_id).where(merchant_account: {gateway: self.class.to_s}).first
        raise "refundable_payment not found for transaction_id #{transaction_id} - #{self.class}" if refundable_payment.nil?
        options[:payment_id] = refundable_payment.id

        add_order(post, options)
        add_boleto_bank_options(post, options) if refundable_payment.boleto?

        commit 'refund', money, post
      end

      def credit(money, credit_card=nil, options = {})
        refund(money, credit_card, options)
      end

      def self.payment_response(params)
        begin
          merchant = MerchantAccount.find_by_gateway_and_password(self.to_s, params[:secret])
          raise "MerchantAccount not found" unless merchant

          case params[:payment_method]
          when 'C' #credit card response
            credit_card_payment(merchant, params)
          when 'B' #boleto response
            boletos = Hash.from_xml(params[:content])['boletos_list']['boleto']
            boletos = [boletos] if boletos.class == Hash
            for boleto in boletos
              boleto_payment(merchant, boleto)
            end
            BoletoBreakdownJob.perform_later
            # raise "BoletoBeta"
          else
            raise "UnsupportedPaymentMethod"
          end
          raise "TestTrans" if Rails.env == 'development'
        rescue Exception => e
          mail_message = "Params:\n"
          params.each { |k, v| mail_message += "  #{k}: => #{v}\n" }
          mail_message += "params = #{params.inspect}\n"
          subject = "Error in PagBrasil.payment_response"
          if e.message == 'BoletoBeta'
            subject = "Boleto Payments"
            mail_message = "Boletos: #{boletos.size}\n\n" + mail_message
          elsif e.message == 'DelayedCardBeta'
            subject = e.message
          end
          subject = "PagBrasil test transaction" if e.message == 'TestTrans'
          Postman.delay.notification(e, mail_message, subject)
          raise e unless e.message.in? 'TestTrans', 'BoletoBeta', 'DelayedCardBeta'
        end
        return "Received successfully in #{Time.now}"
      end

      private

        def self.credit_card_payment(merchant, params)
          #ActiveRecord::Base.logger.debug "Starting credit_card_payment"
          payment = Payment.find(params[:order])
          #ensure_payment_is_pending(payment)
          if params[:payment_status] == PAYMENT_SUCCESSFUL_STATUS
            raise "PagBrasil cc payment amount doesn't match" if payment.amount.to_f != params[:amount_brl].to_f
            payment.update_attributes!( response: 1,
                                        reason_code: 100,
                                        transaction_id: payment.id,
                                        authorization: params[:authorization_code],
                                        display_message: "Aprovado",
                                        gateway_display_message: 'Aprovado')
            update_approved_payment(payment, 'C')
          else
            payment.order.customer_campaign.send_email('declined') if payment.pending? && payment.order
            payment.update_attributes!( response: 2,
                                        reason_code: 200,
                                        display_message: "Seu cartão foi recusado",
                                        gateway_display_message: 'Declinou')
          end
          #ActiveRecord::Base.logger.debug "Ending credit_card_payment"
          raise "DelayedCardBeta" if CardIssuer.brand(payment.account_number).in? 'American Express', 'Hipercard', 'Elo'
        end

        def self.boleto_payment(merchant, boleto)
          original_payment = Payment.find(boleto['order'])
          # make sure the original has a transaction_id
          if original_payment.transaction_id.blank?
            original_payment.transaction_id = "HAL#{original_payment.id}"
            # update the transaction_id without altering the updated_at timestamp. In Rails 3.1 we can do this with a simple update_column.
            Payment.update_all({transaction_id: "HAL#{original_payment.id}"}, {id: original_payment.id})
          end
          copy_values = original_payment.attributes.select { |k,v| k.in?('order_id', 'currency_id', 'description', 'customer_id', 'first_name', 'last_name') }
          payment_attrs = copy_values.merge(action: 'capture',
                                            trans_method: 'B',
                                            amount: boleto['amount_paid'],
                                            response: 1,
                                            reason_code: 100,
                                            transaction_id: original_payment.transaction_id,
                                            reference_transaction_id: original_payment.transaction_id,
                                            display_message: "Aprovado",
                                            gateway_display_message: 'Aprovado')
          payment = merchant.payments.create!(payment_attrs)

          amount_due = boleto['amount_due'].to_f
          margin_percent = 0.05 # 5% margin of error
          margin = amount_due * margin_percent
          mail_message = "Boleto:\n"
          boleto.each { |k, v| mail_message += "  #{k}: => #{v}\n" }

          if boleto['amount_paid'].to_f.in? amount_due-margin..amount_due+margin
            update_approved_payment(payment, 'B')
            unless boleto['amount_paid'].to_f == amount_due
              mail_message += "\nAmount doesn't match, but it was within 5% so it was approved.\n"
              Postman.delay.notification(Exception.new('MismatchBoletoAmount'), mail_message, "Boleto amount doesn't match, but approved")
            end
          else
            Postman.delay.notification(Exception.new('MismatchBoletoAmount'), mail_message, "Boleto amount doesn't match")
          end
        end

        def self.ensure_payment_is_pending(payment)
          raise "Payment.response is not 4 or 5 https://hal.logiql.com/payments/#{payment.id}" unless payment.response.in? 4,5
          max_wait_time = 5 # seconds
          max_wait_time.times do |x|
            break if payment.response == 5 # pending
            ActiveRecord::Base.logger.debug "Sleeping #{Time.now}"
            sleep(1)
          end
          raise "Payment.response is still 4 after waiting #{max_wait_time} seconds https://hal.logiql.com/payments/#{payment.id}" if payment.response == 4
        end

        def self.update_approved_payment(payment, method)
          order = payment.order
          return unless order
          if order.customer_campaign
            order.customer_campaign.set_status('success')
            order.customer_campaign.send_receipt if method == 'C'
            order.customer_campaign.send_email('boleto_receipt') if method == 'B'
          end
          order.update_status('complete')
          order.update_line_item_delivery_types
        end

        def commit(action, money, post)
          begin
            # add amount and secret
            post[:secret] = @options[:password]

            # money needs to be a decimal
            money = money.to_f / 100

            post[:amount_brl]      = money if action == "purchase"
            post[:amount_refunded] = money if action == "refund"

            # PagBrasil doesn't like our default UTF8 encoding, so encode the values using Unicode :decimal. :name would probably work as well
            coder = HTMLEntities.new
            post.each { |k,v| post[k] = coder.encode(v, :decimal) }

            # post data
            time_log = ActiveSupport::OrderedHash.new
            time_log[:before_ssl_post] = Time.now

            url = action == "purchase" ? URL : REFUND_URL
              response = ssl_post(url, post.to_param)

            if action == 'purchase'
              case post[:payment_method]
              when 'B'
                return boleto_response(response, post)
              when 'C'
                return credit_card_response(response, post)
              else
                raise ArgumentError, "Unsupported payment.trans_method in commit"
              end
            elsif action == 'refund'
              return refund_response(response, post)
            end
            #raise 'TestTrans' if test?
          rescue ConnectionError => e
            raise e unless e.message == 'The connection to the remote server timed out'
            raise e unless post[:payment_method] == 'C'
            raise e unless action == 'purchase'
            Postman.delay.notification(e, "Told customer to use a different card.", "PagBrasil ConnectionError")
            return Response.new(false, 'Declined', {},
                                test: test?,
                                gateway_request: "#{URL}?#{post.to_param}",
                                gateway_response: response,
                                gateway_reason_code: 318,
                                gateway_message: 'Recusado. Use um cartão diferentes.', # (Declined. Use a different card.)
                                standard_response: 2)

            # this used to always send an email with debugging info. Now it will decline the card and tell the customer to use a different card.
#            time_log[:exception_raised] = Time.now
#            mail_message = "https://hal.logiql.com/payments/#{post[:order]}\n"
#            mail_message += time_log.collect { |k,v| "[:#{k}] => #{v}" }.join("\n")+"\n"
#            mail_message += "Host: #{ENV['HOSTNAME']}\n"
#            mail_message += "Customer: https://hal.logiql.com/customers/#{Payment.find(post[:order]).customer_id}" rescue "EXCEPTION"
#            Postman.deliver_later(:notification, e, mail_message, "PagBrasil ConnectionError")
#            raise e
          rescue Exception => e
            mail_message = "Post:\n"
            post.each { |k, v| mail_message += "  #{k}: => #{v}\n" }
            mail_message += "\nResponse: #{response}"
            subject = (e.message == 'TestTrans' ? "PagBrasil test transaction" : "Error in PagBrasil.commit")
            Postman.delay.notification(e, mail_message, subject)
            raise e unless e.message == 'TestTrans'
          end
        end

        def credit_card_response(response, post)
          success = response.in? SUCCESSFUL_RESPONSES
          Response.new(success, 'Processing', {},
                            test: test?,
                            gateway_request: "#{URL}?#{post.to_param}",
                            gateway_response: response,
                            gateway_reason_code: 0,
                            gateway_message: 'Processing',
                            standard_response: 5
          )
        end

        def boleto_response(response, post)
          if response.match(/\Ahttp:\/\//)
            success = true
            standard_response = 5
            transaction_id = "HAL#{post[:order]}"
          else
            success = false
            standard_response = 2
            transaction_id = nil
          end
          Response.new(success, response, {},
                            test: test?,
                            gateway_request: "#{URL}?#{post.to_param}",
                            gateway_response: response,
                            gateway_reason_code: 0,
                            gateway_message: 'Pending Payment',
                            standard_response: standard_response,
                            transaction_id: transaction_id
          )
        end

        def refund_response(response, post)
          success = response.in? SUCCESSFUL_RESPONSES
          Response.new(success, response, {},
                      test: test?,
                      gateway_request: "#{REFUND_URL}?#{post.to_param}",
                      gateway_response: response,
                      gateway_reason_code: 0,
                      standard_response: success ? 1 : 2
                      )
        end

        def add_customer_data(post, options)
          # customer_name, customer_taxid, customer_email
          post[:customer_name]  = [options[:first_name], options[:last_name]].join(' ').chomp(' ')
          post[:customer_email] = options[:email]
          add_customer_taxid(post, options)
        end

        def add_customer_taxid(post, options)
          options[:tax_id].gsub!(/\D/, '')
          if Cpf.new(options[:tax_id]).valid? || test?
            post[:customer_taxid] = options[:tax_id]
          else
            raise ArgumentError, "Invalid CPF (#{options[:tax_id]})"
          end
        end

        def add_address(post, options)
          # address_street, address_zip, address_city, address_state, customer_phone
          if address = options[:billing_address] || options[:address]
            post[:address_street]    = [address[:address1].to_s, address[:address2].to_s].join(', ')
            post[:address_zip]        = address[:zip].to_s.gsub(/-/, '')
            post[:address_city]       = address[:city].to_s
            post[:address_state]      = address[:state_code]
            post[:customer_phone]     = address[:phone]
          end
        end

        def add_order(post, options)
          # order
          post[:order] = options[:payment_id]
        end

        def add_product_names(post, options)
          post[:product_name] = options[:description] #TODO required as: ProductName1 (Qty: 3)\nProductName2 (Qty: 1)
        end

        def add_payment_source(params, credit_card, options={})
          case options[:method]
            when 'B' then add_boleto(params, options)
            when 'C' then add_creditcard(params, credit_card, options)
          else
            raise ArgumentError, "Unsupported payment source provided"
          end
        end

        def add_creditcard(post, creditcard, options)
          # cc_installments, cc_brand, cc_holder, cc_number, cc_expiration, cc_cvv
          post[:payment_method] = options[:method]
          post[:cc_installments] = options[:installments]
          post[:cc_number]  = creditcard.number
          post[:cc_cvv] = creditcard.verification_value if creditcard.verification_value?
          post[:cc_expiration]  = expdate(creditcard)
          post[:cc_holder] = [creditcard.first_name, creditcard.last_name].join(' ').chomp(' ')
          add_card_brand(post, options)
        end

        def verify_installments(money, options)
          # money needs to be a decimal
          money = money.to_f / 100

          per_installment = options[:installments].present? ? (money / options[:installments].to_i) : 0.0
          if per_installment <= 5.0
            exc = ArgumentError.new "Unsupported number of installments."
            Postman.delay.notification(exc, "Money: #{money}\nInstallments: #{options[:installments]}\nPer Installment: #{per_installment}", "Error in PagBrasil.add_card_brand")
            raise exc
          end
        end

        def add_boleto(post, options)
          post[:payment_method] = options[:method]
        end

        def add_boleto_bank_options(post, options)
          if options.has_key?(:bank_info) && options[:bank_info].present?
            post[:customer_bank] = options[:bank_info][:customer_bank]
            post[:customer_branch] = options[:bank_info][:customer_branch]
            post[:customer_account] = options[:bank_info][:customer_account]
          else
            raise ArgumentError, "Boleto Refunds require Customer's bank information to be provided."
          end
        end

        def add_card_brand(post, options)
          brand_name = options[:card_brand].downcase.gsub(' ','_').to_sym
          if ACCEPTED_CARD_BRANDS[brand_name]
            post[:cc_brand] = ACCEPTED_CARD_BRANDS[brand_name]
          else
            raise ArgumentError, "Unsupported card brand provided (#{options[:card_brand]})"
          end
        end

        def expdate(creditcard)
          year  = sprintf("%.4i", creditcard.year)
          month = sprintf("%.2i", creditcard.month)

          "#{month}/#{year[-2..-1]}"
        end

    end
  end
end
