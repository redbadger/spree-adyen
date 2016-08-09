module Spree
  class Gateway::AdyenPaymentEncrypted < Gateway
    include AdyenCommon

    preference :public_key, :string

    def self.supports?(source)
      source.cc_type == 'adyen_encrypted'
    end

    def provider_class
      self.class
    end

    def auto_capture?
      false
    end

    def method_type
      'adyen_encrypted'
    end

    def payment_profiles_supported?
      false
    end

    def capture(amount, source, gateway_options = {})
      card = { encrypted: { json: source.encrypted_data } }
      authorize_on_card amount, source, gateway_options, card
    end
  end
end
