module Spree::Chimpy
  module Interface
    class SpreeOrderUpserter
      delegate :log, :store_api_call, :get_campaign_by_id, to: Spree::Chimpy

      # This is a generic Upserter Class for Spree Orders
      #
      # Spree uses a single object to manage Carts and Orders and relies on the
      # Order's status to differentiate between the two.
      #
      # MailChimp, however has a distinct API endpoint for each, which requires
      # Carts and Orders to be handled independently. Most of this process is
      # identical -- the only significant difference is in the URL of the API
      # call and the structure of the JSON object passed to MailChimp.
      #
      # This class handles the common processes, and the order_upserter / cart_upserter
      # handle the custom requirements

      def initialize(order)
        # NOTE: We intentionally use the variable name of @order to maintain
        # consistency with the Spree object (which uses the Order object
        # interchangeably for both Carts and Orders)
        @order = order
      end

      def customer_id
        # Get the Customer ID
        @customer_id ||= CustomerUpserter.new(@order).ensure_customer
        # Ensures that a Customer entity exists in MailChimp's DB
      end

      def upsert
        return unless customer_id

        perform_upsert
      end

      protected

      def perform_upsert
        log "Upsert method not implemented"
      end

      # This method generates a hash object containing the common data elements
      # shared by both Carts and Orders
      #
      # NOTE: Though both carts and orders require the lines: parameter, the
      # structure of the data IN that parameter differs slightly for each endpoint
      #
      # NOTE: Despite the different endpoints, carts and orders are mutually exclusive
      # elements. When adding an ORDER (completed order), any associated carts
      # (in-progress order) should be removed.
      #
      # Using Spree's Order Number as the ID for both Carts and Orders helps facilitate
      # this pairing.
      def common_hash
        source = @order.source

        lines = @order.line_items.map do |line|
          line_item_hash(line)
        end

        data = {
          id:                     @order.number,
          lines:                  lines,
          order_total:            @order.total.to_f,
          currency_code:          @order.currency,
          processed_at_foreign:   @order.completed_at ? @order.completed_at.to_formatted_s(:db) : "",
          updated_at_foreign:     @order.updated_at.to_formatted_s(:db),
          tax_total:              @order.try(:included_tax_total).to_f + @order.try(:additional_tax_total).to_f,
          customer: {
            id: customer_id
          }
        }

        if source && source.campaign_id
          begin
            get_campaign_by_id(source.campaign_id)
            data[:campaign_id] = source.campaign_id
          rescue Gibbon::MailChimpError => e
            log "Campaign with id: #{source.campaign_id} doesn't exist."
          end
        end

        data
      end

      def line_item_hash(line_item)
        variant = line_item.variant
        {
          id: "line_item_#{line_item.id}",
          product_id:    variant.product_id.to_s,
          product_variant_id: variant.id.to_s,
          price:          variant.price.to_f,
          quantity:           line_item.quantity
        }
      end

      def remove_cart
        begin
          store_api_call.carts(@order.number).delete
          # NOTE: Once an Order is complete, we want to remove the Cart record
          # from MailChimp because it is no longer relevant.
          #
          #     NOTE: If the cart is not removed, then it would be included in
          #     automated Abandoned Cart campaigns, which should not happen if
          #     the customer has completed their order.
        rescue Gibbon::MailChimpError => e
          log "Unable to remove cart #{@order.number}. [#{e.raw_body}]"
        end
      end

      # Utility method used to check whether or not an Order record exists in
      # MailChimp for the provided @order
      def mail_chimp_order_exists?
        log "Checking for existing Order record with id #{@order.number}"
        begin
          # Check MailChimp for an Order with the associated ID
          response = store_api_call.orders(@order.number).retrieve(params: { "fields" => "id" })
          # NOTE: This API call will raise a Gibbon::MailChimpError if the Order
          #       does not exist, so any non-error return from the above should
          #       result in a TRUE return from this method.

          return true ## The order EXISTS
        rescue Gibbon::MailChimpError => e
          # NOTE: If we encounter this error here, it means no ORDER exists in
          #       MailChimp for the specified ID. In this case, that's just fine
          #       so we want to swallow the error and move on.

          return false # The order DOES NOT EXIST
        end
      end

      # Utility method used to check whether or not an Cart record exists in
      # MailChimp for the provided @order
      def mail_chimp_cart_exists?
        log "Checking for existing Cart record with id #{@order.number}"
        begin
          # Check MailChimp for a Cart with the associated ID
          store_api_call.carts(@order.number).retrieve(params: { "fields" => "id" })
          # NOTE: This API call will raise a Gibbon::MailChimpError if the Cart
          #       does not exist, so any non-error return from the above should
          #       result in a TRUE return from this method.

          true ## The cart EXISTS
        rescue Gibbon::MailChimpError => e
          # NOTE: If we encounter this error here, it means no ORDER exists in
          #       MailChimp for the specified ID. In this case, that's just fine
          #       so we want to swallow the error and move on.

          false # The cart DOES NOT EXIST
        end
      end
    end
  end
end
