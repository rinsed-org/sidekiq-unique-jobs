module SidekiqUniqueJobs
  module Lock
    class UntilExecuted
      OK ||= 'OK'.freeze

      extend Forwardable
      def_delegators :Sidekiq, :logger

      def initialize(item, redis_pool = nil)
        @item = item
        @redis_pool = redis_pool
      end

      def execute(after_unlock_hook, &blk)
        operative = true
        send(:after_yield_yield, &blk)
      rescue Sidekiq::Shutdown
        operative = false
        raise
      ensure
        after_unlock_hook.call if operative && unlock(:server)
      end

      def unlock(scope)
        unless [:server, :api, :test].include?(scope)
          fail ArgumentError, "#{scope} middleware can't #{__method__} #{unique_key}"
        end
        SidekiqUniqueJobs::Unlockable.unlock(unique_key, item[JID_KEY], redis_pool)
      end

      # rubocop:disable MethodLength
      def lock(scope)
        if scope.to_sym != :client
          fail ArgumentError, "#{scope} middleware can't #{__method__} #{unique_key}"
        end

        result = Scripts.call(:aquire_lock, redis_pool,
                              keys: [unique_key],
                              argv: [item[JID_KEY], max_lock_time])
        case result
        when 1
          logger.debug { "successfully locked #{unique_key} for #{max_lock_time} seconds" }
          true
        when 0
          logger.debug { "failed to aquire lock for #{unique_key}" }
          false
        else
          fail "#{__method__} returned an unexpected value (#{result})"
        end
      end
      # rubocop:enable MethodLength

      def unique_key
        @unique_key ||= UniqueArgs.digest(item)
      end

      def max_lock_time
        @max_lock_time ||= TimeoutCalculator.for_item(item).seconds
      end

      def after_yield_yield
        yield
      end

      private

      attr_reader :item, :redis_pool
    end
  end
end
