require 'hetchy'

module Librato
  class Collector
    # maintains storage of timing and measurement type measurements
    #
    class Aggregator
      extend Forwardable

      def_delegators :@cache, :empty?, :prefix, :prefix=

      def initialize(options={})
        @cache = Librato::Metrics::Aggregator.new(:prefix => options[:prefix])
        @percentiles = {}
        @lock = Mutex.new
      end

      def [](key)
        fetch(key)
      end

      def fetch(key, options={})
        return nil if @cache.empty?
        return fetch_percentile(key, options) if options[:percentile]
        gauges = nil
        source = options[:source]
        @lock.synchronize { gauges = @cache.queued[:gauges] }
        gauges.each do |metric|
          if metric[:name] == key.to_s
            return metric if !source && !metric[:source]
            return metric if source.to_s == metric[:source]
          end
        end
        nil
      end

      def delete_all
        @lock.synchronize { @cache.clear }
      end

      # transfer all measurements to queue and reset internal status
      def flush_to(queue, opts={})
        queued = nil
        @lock.synchronize do
          return if @cache.empty?
          queued = @cache.queued
          @cache.clear unless opts[:preserve]
        end
        queue.merge!(queued) if queued
      end

      # @example Simple measurement
      #   measure 'sources_returned', sources.length
      #
      # @example Simple timing in milliseconds
      #   timing 'twitter.lookup', 2.31
      #
      # @example Block-based timing
      #   timing 'db.query' do
      #     do_my_query
      #   end
      #
      # @example Custom source
      #    measure 'user.all_orders', user.order_count, :source => user.id
      #
      def measure(*args, &block)
        options = {}
        event = args[0].to_s
        returned = nil

        # handle block or specified argument
        if block_given?
          start = Time.now
          returned = yield
          value = ((Time.now - start) * 1000.0).to_i
        elsif args[1]
          value = args[1]
        else
          raise "no value provided"
        end

        # detect options hash if present
        if args.length > 1 and args[-1].respond_to?(:each)
          options = args[-1]
        end
        source = options[:source]
        percentiles = Array(options[:percentile])

        @lock.synchronize do
          if source
            @cache.add event => {:source => source, :value => value}
          else
            @cache.add event => value
          end

          percentiles.each do |perc|
            store = fetch_percentile_store(event, source)
            store << value
          end
        end
        returned
      end
      alias :timing :measure

      private

      def fetch_percentile(key, options)
        store = fetch_percentile_store(key, nil)
        return nil unless store
        store.percentile(options[:percentile])
      end

      def fetch_percentile_store(event, source)
        keyname = source ? "#{event}$$#{source}" : event
        @percentiles[keyname] ||= Hetchy::Reservoir.new(size: 1000)
      end

    end
  end
end