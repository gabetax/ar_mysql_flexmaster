require 'active_record/connection_adapters/mysql2_adapter'
require 'timeout'

module ActiveRecord
  class Base
    def self.mysql_flexmaster_connection(config)
      config = config.symbolize_keys
      hosts = config[:hosts] || [config[:host]]

      config[:username] = 'root' if config[:username].nil?

      if Mysql2::Client.const_defined? :FOUND_ROWS
        config[:flags] = Mysql2::Client::FOUND_ROWS
      end

      ConnectionAdapters::MysqlFlexmasterAdapter.new(logger, config)
    end
  end

  module ConnectionAdapters
    class MysqlFlexmasterAdapter < Mysql2Adapter
      class NoActiveMasterException < Exception; end

      CHECK_EVERY_N_SELECTS = 10
      DEFAULT_CONNECT_TIMEOUT = 5
      DEFAULT_TX_HOLD_TIMEOUT = 5

      def initialize(logger, config)
        @select_counter = 0
        @config = config
        @is_master = !config[:slave]
        @tx_hold_timeout = @config[:tx_hold_timeout] || DEFAULT_TX_HOLD_TIMEOUT
        @connection_timeout = @config[:connection_timeout] || DEFAULT_CONNECT_TIMEOUT
        connection = find_correct_host
        raise NoActiveMasterException unless connection
        super(connection, logger, [], config)
      end

      def begin_db_transaction
        if !cx_correct? && open_transactions == 0
          refind_correct_host
        end
        super
      end

      def execute(sql, name = nil)
        if open_transactions == 0 && sql =~ /^(INSERT|UPDATE|DELETE|ALTER|CHANGE)/ && !cx_correct?
          refind_correct_host
        else
          @select_counter += 1
          if (@select_counter % CHECK_EVERY_N_SELECTS == 0) && !cx_correct?
            # on select statements, check every 10 times to see if we need to switch masters,
            # but don't hold off anything if we fail
            refind_correct_host(1, 0)
          end
        end
        super
      end

      private

      def connect
        @connection = find_correct_host
        raise NoActiveMasterException unless @connection
      end

      def refind_correct_host(tries = nil, sleep_interval = nil)
        tries ||= @tx_hold_timeout.to_f / 0.1
        sleep_interval ||= 0.1
        tries.to_i.times do
          cx = find_correct_host
          if cx
            flush_column_information
            @connection = cx
            return
          end
          sleep(sleep_interval)
        end
        raise NoActiveMasterException
      end

      def hosts_and_ports
        @hosts_and_ports ||= @config[:hosts].map do |hoststr|
          host, port = hoststr.split(':')
          port = port.to_i unless port.nil?
          [host, port]
        end
      end

      def find_correct_host
        cxs = hosts_and_ports.map do |host, port|
          initialize_connection(host, port)
        end

        correct_cxs = cxs.select { |cx| cx && cx_correct?(cx) }

        if @is_master
          # for master connections, we make damn sure that we have just one master
          if correct_cxs.size == 1
            return correct_cxs.first
          else
            # nothing read-write, or too many read-write
            # (should we manually close the connections?)
            return nil
          end
        else
          # for slave connections, we just return a random RO candidate
          return correct_cxs.shuffle.first
        end
      end

      def initialize_connection(host, port)
        begin
          Timeout::timeout(@connection_timeout) do
            cfg = @config.merge(:host => host, :port => port)
            Mysql2::Client.new(cfg).tap do |cx|
              cx.query_options.merge!(:as => :array)
            end
          end
        rescue Mysql2::Error
        rescue Timeout::Error
        end
      end

      def flush_column_information
        ActiveRecord::Base.descendants.each do |k|
          k.reset_column_information
        end
      end

      def cx_correct?(cx = @connection)
        res = cx.query("SELECT @@read_only as ro").first

        if @is_master
          res.first == 0
        else
          res.first == 1
        end
      end
    end
  end
end
