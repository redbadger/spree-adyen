module Spree
  module AdyenCommon
    extend ActiveSupport::Concern

    class RecurringDetailsNotFoundError < StandardError; end

    included do
      preference :api_username, :string
      preference :api_password, :string
      preference :merchant_account, :string

      def client
        @client ||= ::Adyen::REST.client
      end

      def merchant_account
        ENV['ADYEN_MERCHANT_ACCOUNT'] || preferred_merchant_account
      end

      def provider
        ::Adyen.configuration.api_username = (ENV['ADYEN_API_USERNAME'] || preferred_api_username)
        ::Adyen.configuration.api_password = (ENV['ADYEN_API_PASSWORD'] || preferred_api_password)
        ::Adyen.configuration.default_api_params[:merchant_account] = merchant_account

        client
      end

      # NOTE Override this with your custom logic for scenarios where you don't
      # want to redirect customer to 3D Secure auth
      def require_3d_secure?(payment)
        true
      end

      # Receives a source object (e.g. CreditCard) and a shopper hash
      def require_one_click_payment?(source, shopper)
        false
      end

      def capture(amount, response_code, gateway_options = {})
        value = { currency: gateway_options[:currency], value: amount }
        response = provider.capture_payment(response_code, value)

        if response.authorised?
          def response.authorization; psp_reference; end
          def response.avs_result; {}; end
          def response.cvv_result; {}; end
          def response.success?; authorised?; end
        else
          # TODO confirm the error response will always have these two methods
          def response.to_s
            self['refusal_reason']
          end
        end

        response
      end

      # According to Spree Processing class API the response object should respond
      # to an authorization method which return value should be assigned to payment
      # response_code
      def void(response_code, source, gateway_options = {})
        response = provider.cancel_payment(response_code)

        if response.authorised?
          def response.authorization; psp_reference; end
          def response.success?; authorised?; end
        else
          # TODO confirm the error response will always have these two methods
          def response.to_s
            self['refusal_reason']
          end
        end
        response
      end

      def credit(credit_cents, source, response_code, gateway_options)
        amount = { currency: gateway_options[:currency], value: credit_cents }
        response = provider.refund_payment response_code, amount

        if response.authorised?
          def response.authorization; psp_reference; end
          def response.success?; authorised?; end
        else
          def response.to_s
            self['refusal_reason']
          end
        end

        response
      end

      def disable_recurring_contract(source)
        response = provider.disable_recurring_contract source.user_id, source.gateway_customer_profile_id

        if response.authorised?
          source.update_column :gateway_customer_profile_id, nil
        else
          logger.error(Spree.t(:gateway_error))
          logger.error("  #{response.to_yaml}")
          raise Core::GatewayError.new(response.fault_message || response.refusal_reason)
        end
      end

      def build_authorise_details(payment)
        if payment.request_env.is_a?(Hash) && require_3d_secure?(payment)
          {
            browser_info: {
              accept_header: payment.request_env['HTTP_ACCEPT'],
              user_agent: payment.request_env['HTTP_USER_AGENT']
            },
            recurring: true
          }
        else
          { recurring: true }
        end
      end

      def build_amount_on_profile_creation(payment)
        { currency: payment.currency, value: payment.money.money.cents }
      end

      private

        def set_up_contract(source, card, user, shopper_ip)
          gateway_options = {
            currency: Spree::Config.currency,
            order_id: "User-#{user.id}",
            customer_id: user.id,
            email: user.email,
            ip: shopper_ip
          }

          response = authorize_on_card 0, source, gateway_options, card, { recurring: true }

          if response.authorised?
            fetch_and_update_contract source, options[:customer_id]
          else
            response['refusal_reason']
          end
        end

        def authorize_on_card(amount, source, gateway_options, card, options = { recurring: false })
          reference = gateway_options[:order_id]

          amount = { currency: gateway_options[:currency], value: amount }

          shopper_reference = if gateway_options[:customer_id].present?
                                gateway_options[:customer_id]
                              else
                                gateway_options[:email]
                              end

          shopper = { :reference => shopper_reference,
                      :email => gateway_options[:email],
                      :ip => gateway_options[:ip],
                      :statement => "Order # #{gateway_options[:order_id]}" }

          response = decide_and_authorise reference, amount, shopper, source, card, options

          # Needed to make the response object talk nicely with Spree payment/processing api
          if response.authorised?
            def response.authorization; psp_reference; end
            def response.avs_result; {}; end
            def response.cvv_result; { 'code' => result_code }; end
            def response.success?; authorised?; end
          else
            def response.to_s
              self['refusal_reason']
            end
          end

          response
        end

        def decide_and_authorise(reference, amount, shopper, source, card, options)
          recurring_detail_reference = source.gateway_customer_profile_id
          card_cvc = source.verification_value

          if card_cvc.blank? && require_one_click_payment?(source, shopper)
            raise Core::GatewayError.new("You need to enter the card verificationv value")
          end

          attributes = {
            shopper_email: shopper[:email],
            shopper_reference: shopper[:reference],
            shopper_ip: shopper[:ip],
            merchant_account: merchant_account,
            amount: amount,
            reference: reference,
            recurring: options && options[:recurring],
            browser_info: {
              accept_header: source.request_env['HTTP_ACCEPT'],
              user_agent: source.request_env['HTTP_USER_AGENT']
            }
          }

          attributes = card[:encrypted] ? attributes.merge(additional_data: { card: card }) : attributes.merge(card: card)

          if require_one_click_payment?(source, shopper) && recurring_detail_reference.present?
            provider.authorise_one_click_payment(attributes)
          elsif options[:recurring]
            provider.authorise_recurring_payment(attributes)
          else
            res = provider.authorise_payment(attributes)
            res
          end
        end

        # FOLLOWING METHODS UNUSED - We've disabled payment profile support as it requires an additional payment
        # authorisation. As we use auto-capture, we'd need to void the payment immediately afterwards which is
        # currently unimplemented.

        def create_profile_on_card(payment, card)
          unless payment.source.gateway_customer_profile_id.present?
            ip = payment.order.last_ip_address
            shopper = { :reference => (payment.order.user_id.present? ? payment.order.user_id : payment.order.email),
                        :email => payment.order.email,
                        :ip => ip,
                        :statement => "Order # #{payment.order.number}" }

            amount = build_amount_on_profile_creation payment
            options = build_authorise_details payment

            attributes = {
              shopper_ip: ip,
              merchant_account: merchant_account,
              amount: amount,
              reference: payment.order.number,
              recurring: options && options[:recurring],
              fraud_offset: nil,
              browser_info: {
                accept_header: payment.request_env['HTTP_ACCEPT'],
                user_agent: payment.request_env['HTTP_USER_AGENT']
              }
            }

            attributes = card[:encrypted] ? attributes.merge(additional_data: { card: card }) : attributes.merge(card: card)

            response = provider.authorise_payment(attributes)

            if response.authorised?
              fetch_and_update_contract payment.source, shopper[:reference]

              # Avoid this payment from being processed and so authorised again
              # once the order transitions to complete state.
              # See Spree::Order::Checkout for transition events
              payment.started_processing!

            elsif response.redirect_shopper?
              raise Adyen::Enrolled3DError.new(response, payment.payment_method)
            else
              logger.error(Spree.t(:gateway_error))
              logger.error("  #{response.to_yaml}")
              raise Core::GatewayError.new(response['refusal_reason'])
            end

            response
          end
        end

        def fetch_and_update_contract(source, shopper_reference)
          # Adyen doesn't give us the recurring reference (token) so we
          # need to reach the api again to grab the token
          list = provider.list_recurring_details(merchant_account: merchant_account, shopper_reference: shopper_reference)
          fail RecurringDetailsNotFoundError unless list.references.present?

          source.update_columns(
            month: list.details.last[:card_expiry_month],
            year: list.details.last[:card_expiry_year],
            name: list.details.last[:card_holder_name],
            cc_type: list.details.last[:variant],
            last_digits: list.details.last[:card_number],
            gateway_customer_profile_id: list.references.last
          )
        end
    end

    module ClassMethods
    end
  end
end
