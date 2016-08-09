module Spree
  class Gateway::AdyenPaymentEncrypted < Gateway
    include AdyenCommon

    preference :public_key, :string

    def self.supports?(cc_type)
      cc_type == 'adyen_encrypted'
    end

    def provider_class
      self.class
    end

    def auto_capture?
      true
    end

    def method_type
      'adyen_encrypted'
    end

    def payment_profiles_supported?
      false
    end

    def purchase(amount, source, gateway_options = {})
      card = { encrypted: { json: source.encrypted_data } }

      payment = source.payments.last

      # Our Spree customisations include 3D Secure fields on the payment model
      if payment.try(:md?)
        authorise_3d_secure(payment.md, gateway_options)
      else
        authorize_on_card(amount, source, gateway_options, card)
      end
    end

    # Do a symbolic authorization, e.g. 1 dollar, so that we can grab a recurring token
    #
    # NOTE Ensure that your Adyen account Capture Delay is set to *manual* otherwise
    # this amount might be captured from customers card. See Settings > Merchant Settings
    # in Adyen dashboard
    def create_profile(payment)
      card = { encrypted: { json: payment.source.encrypted_data } }
      create_profile_on_card payment, card
    end

    def add_contract(source, user, shopper_ip)
      card = { encrypted: { json: source.encrypted_data } }
      set_up_contract source, card, user, shopper_ip
    end
  end
end
