require 'active_record/connection_adapters/mysql2_adapter'

module ActiveRecord
  class Base
    def self.mysql_flexmaster_connection(config)
      config = config.symbolize_keys
      hosts = config[:hosts]

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

      CHECK_RW_EVERY_N_SELECTS = 10

      def initialize(logger, config)
        @select_counter = 0
        @config = config
        @tx_hold_timeout = @config[:tx_hold_timeout] || 5
        connection = find_active_master
        raise NoActiveMasterException unless connection
        super(connection, logger, [], config)
      end

      def begin_db_transaction
        if !cx_rw? && open_transactions == 0
          refind_active_master
        end
        super
      end

      def execute(sql, name = nil)
        if open_transactions == 0 && sql =~ /^(INSERT|UPDATE|DELETE|ALTER|CHANGE)/ && !cx_rw?
          refind_active_master
        else
          @select_counter += 1
          if (@select_counter % CHECK_RW_EVERY_N_SELECTS == 0) && !cx_rw?
            # on select statements, check every 10 times to see if we need to switch masters,
            # but don't hold off anything if we fail
            refind_active_master(1, 0)
          end
        end
        super
      end

      private
      def refind_active_master(tries = nil, sleep_interval = nil)
        tries ||= @tx_hold_timeout.to_f / 0.1
        sleep_interval ||= 0.1
        tries.to_i.times do
          cx = find_active_master
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

      def find_active_master
        cxs = hosts_and_ports.map do |host, port|
          cfg = @config.merge(:host => host, :port => port)
          Mysql2::Client.new(cfg).tap do |cx|
            cx.query_options.merge!(:as => :array)
          end
        end

        rw_cxs = cxs.select { |cx| cx_rw?(cx) }

        if rw_cxs.size == 1
          return rw_cxs.first
        else
          # nothing read-write, or too many read-write
          # (should we manually close the connections?)
          return nil
        end
      end

      def flush_column_information
        ActiveRecord::Base.descendants.each do |k|
          k.reset_column_information
        end
      end

      def cx_rw?(cx = @connection)
        res = cx.query("SELECT @@read_only as ro").first
        res.first == 0
      end
    end
  end
end
