require 'spec_helper'

module Spree
  describe Payment do
    let(:order) { create(:order) }

    let(:details_response) do
      card = { card_expiry_date: 8, card_expiry_year: 1.year.from_now, card_number: '1111' }
      double('List', details: [card], references: ['123432423'])
    end

    let(:response) do
      double("Response",
        psp_reference: "psp",
        result_code: "accepted",
        authorised?: true,
        additional_data: { "cardSummary" => "1111" }
      )
    end

    context "Adyen Payments" do
      let(:payment_method) do
        Gateway::AdyenPayment.create(
          name: "Adyen",
          environment: "test",
          preferred_merchant_account: "Test",
          preferred_api_username: "Test",
          preferred_api_password: "Test"
        )
      end

      let(:credit_card) do
        CreditCard.create! do |cc|
          cc.name = "Washington"
          cc.number = "4111111111111111"
          cc.month = "06"
          cc.year = Time.now.year + 1
          cc.verification_value = "737"
        end
      end

      before do
        request_env = { 'HTTP_ACCEPT' => 'accept', 'HTTP_USER_AGENT' => 'agent' }
        allow_any_instance_of(Spree::Payment).to receive(:request_env).and_return(request_env)

        expect(payment_method.provider).to receive(:authorise_payment).and_return(response)
        expect(payment_method.provider).to receive(:list_recurring_details).and_return(details_response)
      end

      it 'set up a profile on payment creation' do
        Payment.create! do |p|
          p.order_id = order.id
          p.amount = order.total
          p.source = credit_card
          p.payment_method = payment_method
        end

        expect(credit_card.reload.gateway_customer_profile_id).not_to be_empty
      end

      it "voids payments" do
        payment = Payment.create! do |p|
          p.order_id = order.id
          p.amount = order.total
          p.source = credit_card
          p.payment_method = payment_method
        end

        expect(payment_method.provider).to receive(:cancel_payment).and_return(response)
        expect(payment.void_transaction!).to be
      end

      pending "refund payments", "need to figure the new refund stuff on edge" do
        payment = Payment.create! do |p|
          p.order_id = order.id
          p.amount = order.total
          p.source = credit_card
          p.payment_method = payment_method
        end

        expect(payment_method.provider).to receive(:refund_payment).and_return(response)
        expect(payment.credit!).to be_a Spree::Payment
      end
    end

    context "Adyen Payment Encrypted" do
      let(:payment_method) do
        Gateway::AdyenPaymentEncrypted.create(
          name: "Adyen",
          preferred_merchant_account: "Test",
          preferred_api_username: "Test",
          preferred_api_password: "Test",
          preferred_public_key: "Tweewfweffefw"
        )
      end

      let(:credit_card) do
        CreditCard.create! do |cc|
          cc.encrypted_data = "weregergrewgregrewgregewrgewg"
        end
      end

      before do
        expect(payment_method.provider).to_not receive(:authorise_payment)
        expect(payment_method.provider).to_not receive(:list_recurring_details)
      end

      it 'does not set up a payment profile on creation' do
        Payment.create! do |p|
          p.order_id = order.id
          p.amount = order.total
          p.source = credit_card
          p.payment_method = payment_method
        end

        expect(credit_card.reload.gateway_customer_profile_id).to be_nil
      end
    end
  end
end
