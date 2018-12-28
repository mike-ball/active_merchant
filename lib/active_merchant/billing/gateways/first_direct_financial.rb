require 'active_merchant/billing/gateways/transaction_gateway'
module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class FirstDirectFinancial < TransactionGateway
      # documentation: https://fdf.transactiongateway.com/merchants/resources/integration/integration_portal.php#methodology

      self.live_url = 'https://fdf.transactiongateway.com/api/transact.php'

      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club, :maestro]
      self.homepage_url = 'https://fdf.transactiongateway.com'
      self.default_currency = 'USD'
      self.display_name = 'First Direct Financial'
      self.abbreviation = 'FirstDirect'
    end
  end
end
