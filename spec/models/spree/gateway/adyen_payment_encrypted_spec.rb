require 'spec_helper'

module Spree
  describe Gateway::AdyenPaymentEncrypted do
    let(:response) do
      res = double("Response", psp_reference: "psp", result_code: "accepted", authorised?: true)
      def res.[](_); refusal_reason; end
      res
    end

    let(:credit_card) do
      cc = create(:credit_card, last_digits: nil, encrypted_data: 'encrypted_card_data')
      cc.payments << create(:payment, amount: 30000, state: 'checkout')
      cc.save!

      cc
    end

    context "successfully authorized" do
      it "adds processing api calls to response object" do
        browser_info = { browser_info: { accept_header: 'accept', user_agent: 'agent' } }
        expect(subject.provider).to receive(:authorise_payment).with(hash_including(browser_info)).and_return(response)

        result = subject.authorize(30000, credit_card, request_env: { 'HTTP_ACCEPT' => 'accept', 'HTTP_USER_AGENT' => 'agent' })

        expect(result.authorization).to eq response.psp_reference
        expect(result.cvv_result['code']).to eq response.result_code
      end
    end

    context "ensure adyen validations goes fine" do
      let(:gateway_options) do
        { order_id: 17,
          email: "surf@uk.com",
          customer_id: 1,
          ip: "127.0.0.1",
          currency: 'USD',
          request_env: {} }
      end

      before do
        subject.preferred_merchant_account = "merchant"
        subject.preferred_api_username = "admin"
        subject.preferred_api_password = "123"

        # Watch out as we're stubbing private method here to avoid reaching network
        # we might need to stub another method in future adyen gem versions
        allow(subject.provider).to receive(:execute_request).and_return(response)
      end

      it "adds processing api calls to response object" do
        expect {
          subject.authorize(30000, credit_card, gateway_options)
        }.not_to raise_error

        credit_card.gateway_customer_profile_id = "123"
        expect {
          subject.authorize(30000, credit_card, gateway_options)
        }.not_to raise_error
      end

      it "user order email as shopper reference when theres no user" do
        credit_card.gateway_customer_profile_id = "123"
        gateway_options[:customer_id] = nil

        expect {
          subject.authorize(30000, credit_card, gateway_options)
        }.not_to raise_error
      end
    end

    context "refused" do
      let(:response) do
        res = double("Response", authorised?: false, result_code: "Refused", refusal_reason: "010 Not allowed")
        def res.[](_); refusal_reason; end
        res
      end

      before do
        allow(subject.provider).to receive(:execute_request).and_return(response)
      end

      it "response obj print friendly message" do
        result = subject.authorize(30000, credit_card, request_env: {})
        expect(result.to_s).to include(response.refusal_reason)
      end
    end

    context "profile creation" do
      let(:payment) { create(:payment) }

      let(:details_response) do
        card = { card_expiry_date: 8, card_expiry_year: 1.year.from_now, card_number: '1111' }
        double('List', details: [card], references: ['123432423'])
      end

      before do
        request_env = { 'HTTP_ACCEPT' => 'accept', 'HTTP_USER_AGENT' => 'agent' }
        allow_any_instance_of(Spree::Payment).to receive(:request_env).and_return(request_env)

        expect(subject.provider).to receive(:authorise_payment).and_return response
        expect(subject.provider).to receive(:list_recurring_details).and_return details_response
        payment.source.gateway_customer_profile_id = nil
      end

      it "authorizes payment to set up recurring transactions" do
        subject.create_profile payment
        expect(payment.source.gateway_customer_profile_id).to eq details_response.references.last
      end

      it "builds authorise details options" do
        expect(subject).to receive(:build_authorise_details)
        subject.create_profile payment
      end

      it "set payment state to processing" do
        subject.create_profile payment
        expect(payment.state).to eq "processing"
      end

      context 'without an associated user' do
        it "sets last recurring detail reference returned on payment source" do
          payment.order = Order.create number: "R2342345435", last_ip_address: "127.0.0.1"
          subject.create_profile payment

          expect(payment.source.gateway_customer_profile_id).to be_present
        end
      end
    end

    context "Adding recurring contract via $0 auth" do
      let(:shopper_ip) { "127.0.0.1" }
      let(:user) { double("User", id: 358, email: "spree@hq.com") }
      let(:source) do
        CreditCard.create! do |cc|
          cc.name = "Spree Dev Check"
          cc.verification_value = "737"
          cc.month = "06"
          cc.year = Time.now.year + 1
          cc.number = nil
          cc.encrypted_data = 'encrypted_card_data'
        end
      end

      before do
        subject.preferred_merchant_account = test_credentials["merchant_account"]
        subject.preferred_api_username = test_credentials["api_username"]
        subject.preferred_api_password = test_credentials["api_password"]
      end

      it "brings last recurring contract info", external: true do
        source.encrypted_data = nil

        VCR.use_cassette "add_contract" do
          subject.add_contract source, user, shopper_ip
        end
      end
    end

    context "one click payment auth" do
      before do
        allow(subject).to receive(:require_one_click_payment?).and_return(true)
      end

      let(:credit_card) do
        cc = create(
          :credit_card,
          gateway_customer_profile_id: 1,
          verification_value: 1,
          name: 'Spree',
          number: nil,
          encrypted_data: 'encrypted_card_data',
          month: 8,
          year: 1.year.from_now
        )

        cc.payments << create(:payment, amount: 30000, state: 'checkout')
        cc.save!

        cc
      end

      it "adds processing api calls to response object" do
        expect(subject.provider).to receive(:authorise_one_click_payment).and_return response
        result = subject.authorize(30000, credit_card, request_env: {})
      end
    end

    context "builds authorise details" do
      let(:payment) { double("Payment", request_env: {}) }

      it "returns browser info when 3D secure is required" do
        expect(subject.build_authorise_details payment).to have_key :browser_info
      end

      context "doesnt require 3d secure" do
        before { allow(subject).to receive(:require_3d_secure?).and_return(false) }

        it "doesnt return browser info" do
          expect(subject.build_authorise_details payment).to_not have_key :browser_info
        end
      end
    end

    context "real external profile creation", external: true do
      before do
        subject.preferred_merchant_account = test_credentials["merchant_account"]
        subject.preferred_api_username = test_credentials["api_username"]
        subject.preferred_api_password = test_credentials["api_password"]
      end

      let(:order) do
        user = stub_model(LegacyUser, email: "spree@example.com", id: rand(50))
        stub_model(Order, id: 1, number: "R#{Time.now.to_i}-test", email: "spree@example.com", last_ip_address: "127.0.0.1", user: user)
      end

      it "sets profiles" do
        credit_card = CreditCard.new do |cc|
          cc.name = "Washington Braga"
          cc.number = nil
          cc.month = '08'
          cc.year = '2018'
          cc.verification_value = "737"
          cc.encrypted_data = 'encrypted_card_data'
        end

        payment = Payment.new do |p|
          p.order = order
          p.amount = 1
          p.source = credit_card
          p.payment_method = subject
          p.request_env = {}
        end

        order.user_id = 33242

        VCR.use_cassette("profiles/set") do
          subject.save
          payment.save!
          expect(credit_card.gateway_customer_profile_id).not_to be_empty
        end
      end

      context "3-D enrolled credit card" do
        let(:credit_card) do
          CreditCard.create! do |cc|
            cc.name = "Washington Braga"
            cc.number = nil
            cc.month = "06"
            cc.year = Time.now.year + 1
            cc.verification_value = "737"
            cc.encrypted_data = 'encrypted_card_data'
          end
        end

        let(:env) do
          {
            "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.9; rv:29.0) Gecko/20100101 Firefox/29.0",
            "HTTP_ACCEPT"=> "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
          }
        end

        def set_up_payment
          Payment.create! do |p|
            p.order = order
            p.amount = 1
            p.source = credit_card
            p.payment_method = subject
            p.request_env = env
          end
        end

        it "raises custom exception" do
          subject.save

          VCR.use_cassette("3D-Secure") do
            expect {
              set_up_payment
            }.to raise_error Adyen::Enrolled3DError
          end
        end

        it "doesn't persist new payments" do
          subject.save

          VCR.use_cassette("3D-Secure") do
            payments = Payment.count
            expect { set_up_payment }.to raise_error Adyen::Enrolled3DError
            expect(payments).to eq Payment.count
          end
        end
      end
    end
  end
end
