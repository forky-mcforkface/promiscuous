require 'poseidon'
require 'poseidon_cluster'

class Promiscuous::Kafka::Poseidon
  attr_accessor :connection, :connection_lock

  def initialize
    # The poseidon socket doesn't like when multiple threads access to it apparently
    @connection_lock = Mutex.new
  end

  def new_connection
    client_id = ['promiscuous', Promiscuous::Config.app, Poseidon::Cluster.guid].join('.')
    @connection = ::Poseidon::Producer.new(Promiscuous::Config.kafka_hosts, client_id,
                                          :type => :sync,
                                          :compression_codec => :none,
                                          :metadata_refresh_interval_ms => 600_000,
                                          :max_send_retries => 10,
                                          :retry_backoff_ms => 100,
                                          :required_acks => 1,
                                          :ack_timeout_ms => 1000,
                                          :socket_timeout_ms => Promiscuous::Config.socket_timeout)
    @connection
  end

  def connect
    @connection = new_connection
  end

  def disconnect
    @connection_lock.synchronize do
      return unless connected?
      @connection.shutdown
      @connection = nil
    end
  end

  # TODO: extend Poseidon with a connected? method
  def connected?
    !@connection.nil?
  end

  def raw_publish(options)
    ok = @connection.send_messages([Poseidon::MessageToSend.new(options[:topic], options[:payload], options[:key])])
    raise "Unable to send messages" if !ok
    Promiscuous.debug "[publish] [kafka] #{options[:topic]}/#{options[:topic_key]} #{options[:payload]}"
  end

  def publish(options={})
    @connection_lock.synchronize do
      raw_publish(options)
      options[:on_confirm].call if options[:on_confirm]
    end
  rescue Exception => e
    Promiscuous.warn("[publish] Failure publishing to kafka #{e}\n#{e.backtrace.join("\n")}")
    e = Promiscuous::Error::Publisher.new(e, :payload => options[:payload])

    if options[:async]
      Promiscuous::Config.error_notifier.call(e)
    else
      raise e
    end
  end

  module Subscriber
    def subscribe(topic)
      @consumer = ::Poseidon::ConsumerGroup.new(Promiscuous::Config.app,
                                                Promiscuous::Config.kafka_hosts,
                                                Promiscuous::Config.zookeeper_hosts,
                                                topic, :trail => Promiscuous::Config.test_mode, :max_wait_ms => 10)
    end

    def fetch_and_process_messages(&block)
      Promiscuous.debug "[kafka] Fetching messages topic:#{@consumer.topic} #{Thread.current.object_id}"
      @consumer.fetch(:commit => false) do |partition, payloads|
        Promiscuous.debug "[kafka] Fetched payloads:#{payloads.count} topic:#{@consumer.topic} partition:#{partition} #{Thread.current.object_id}"
        payloads.each do |payload|
          Promiscuous.debug "[kafka] Processing '#{payload.value}' topic:#{@consumer.topic} offset:#{payload.offset} parition:#{partition} #{Thread.current.object_id}"
          block.call(MetaData.new(@consumer, partition, payload.offset), payload)
        end
      end
    end

    def delete_queues
      # TODO: implement, possibly keep inside of the specs
      # Promiscuous::Config.subscriber_topics.each { |queue| queue.try(:delete) }
    end

    class MetaData
      def initialize(consumer, partition, offset)
        @consumer = consumer
        @partition = partition
        @offset = offset

        Promiscuous.debug "[kafka] [metadata] topic:#{@consumer.topic} offset:#{offset} partition:#{partition}"
      end

      # TODO: rename to advance_offset or commit?
      def ack
        Promiscuous.debug "[kafka] [commit] topic:#{@consumer.topic} offset:#{@offset+1} partition:#{@partition}"
        @consumer.commit(@partition, @offset+1)
      end
    end

    def disconnect
      @consumer.close
    end
  end
end
