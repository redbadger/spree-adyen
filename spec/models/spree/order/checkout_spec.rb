require 'spec_helper'
require 'spree/testing_support/order_walkthrough'

module Spree
  describe Order do
    context 'with an associated user' do
      let(:order) { OrderWalkthrough.up_to(:delivery) }
      let(:credit_card) { create(:credit_card, cc_type: 'adyen_encrypted') }

      let(:gateway) do
        Gateway::AdyenPaymentEncrypted.create(
          name: 'Adyen',
          environment: 'test',
          preferred_merchant_account: 'Test',
          preferred_api_username: 'Test',
          preferred_api_password: 'Test'
        )
      end

      let(:response) do
        res = double('Response', psp_reference: 'psp', result_code: 'accepted', authorised?: true)
        def res.[](_); refusal_reason; end
        res
      end

      let(:details) do
        card = { card_expiry_date: 8, card_expiry_year: 1.year.from_now, card_number: '1111' }
        double('List', details: [card], references: ['123432423'])
      end

      it 'successfully processes non-3D Secure payments using the AdyenPaymentEncrypted gateway' do
        expect(order.state).to eq 'payment'

        payment = order.payments.create! do |p|
          p.amount = order.total
          p.source = credit_card
          p.payment_method = gateway
        end

        expect(payment).to receive(:gateway_options).and_return(request_env: {})
        expect(gateway.provider).to receive(:authorise_payment).and_return(response)
        payment.process!

        order.payment_total = payment.amount
        order.next!

        expect(order.state).to eq 'complete'
      end
    end
  end
end
