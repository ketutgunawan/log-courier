# encoding: utf-8

# Copyright 2014 Jason Woods.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'ffi-rzmq'
require 'timeout'

module LogCourier
  # ZMQ transport implementation for the server
  class ServerZmq
    class ZMQError < StandardError; end

    attr_reader :port

    def initialize(options = {})
      @options = {
        :logger           => nil,
        :transport        => 'zmq',
        :port             => 0,
        :address          => '0.0.0.0',
        :curve_secret_key => nil
      }.merge(options)

      @logger = @options[:logger]

      if @options[:transport] == 'zmq'
        raise '[LogCourierServer] \'curve_secret_key\' is required' if @options[:curve_secret_key].nil?

        raise '[LogCourierServer] \'curve_secret_key\' must be a valid 40 character Z85 encoded string' if @options[:curve_secret_key].length != 40 || !z85validate(@options[:curve_secret_key])
      end

      begin
        @context = ZMQ::Context.new
        @socket = @context.socket(ZMQ::REP)

        if @options[:transport] == 'zmq'
          rc = @socket.setsockopt(ZMQ::CURVE_SERVER, 1)
          raise ZMQError, 'setsockopt CURVE_SERVER failure: ' + ZMQ::Util.error_string unless ZMQ::Util.resultcode_ok?(rc)

          rc = @socket.setsockopt(ZMQ::CURVE_SECRETKEY, @options[:curve_secret_key])
          raise ZMQError, 'setsockopt CURVE_SECRETKEY failure: ' + ZMQ::Util.error_string unless ZMQ::Util.resultcode_ok?(rc)
        end

        bind = 'tcp://' + @options[:address] + (@options[:port] == 0 ? ':*' : ':' + @options[:port].to_s)
        rc = @socket.bind(bind)
        raise ZMQError, 'failed to bind at ' + bind + ': ' + rZMQ::Util.error_string unless ZMQ::Util.resultcode_ok?(rc)

        # Lookup port number that was allocated in case it was set to 0
        endpoint = ''
        rc = @socket.getsockopt(ZMQ::LAST_ENDPOINT, endpoint)
        raise ZMQError, 'getsockopt LAST_ENDPOINT failure: ' + ZMQ::Util.error_string unless ZMQ::Util.resultcode_ok?(rc) && %r{\Atcp://(?:.*):(?<endpoint_port>\d+)\0\z} =~ endpoint
        @port = endpoint_port.to_i

        @poller = ZMQ::Poller.new

        if @options[:port] == 0
          @logger.warn '[LogCourierServer] Transport is listening on ephemeral port ' + @port.to_s
        end
      rescue => e
        raise "[LogCourierServer] Failed to initialise: #{e}"
      end

      # TODO: Implement workers option by receiving on a ROUTER and proxying to a DEALER, with workers connecting to the DEALER

      reset_timeout
    end

    def z85validate(z85)
      # ffi-rzmq does not implement decode - but we want to validate during startup
      decoded = FFI::MemoryPointer.from_string(' ' * (8 * z85.length / 10))
      ret = LibZMQ.zmq_z85_decode decoded, z85
      return false if ret.nil?

      true
    end

    def run(&block)
      loop do
        begin
          # Try to receive a message
          data = ''
          rc = @socket.recv_string(data, ZMQ::DONTWAIT)
          unless ZMQ::Util.resultcode_ok?(rc)
            raise ZMQError, 'recv_string error: ' + ZMQ::Util.error_string if ZMQ::Util.errno != ZMQ::EAGAIN

            # Wait for a message to arrive, handling timeouts
            @poller.deregister @socket
            @poller.register_readable @socket
            raise Timeout::Error if @poller.poll((@timeout - Time.now.to_i) * 1_000) == 0
            next
          end
        rescue Timeout::Error
          # We'll let ZeroMQ manage reconnections and new connections
          # There is no point in us doing any form of reconnect ourselves
          # We will keep this timeout in however, for shutdown checks
          reset_timeout
          next
        rescue ZMQError => e
          @logger.warn "[LogCourierServer] ZMQ recv_string failed: #{e}" unless @logger.nil?
          next
        end
        # We only work with one part messages at the moment
        if @socket.more_parts?
          @logger.warn '[LogCourierServer] Invalid message: multipart unexpected' unless @logger.nil?
        else
          recv(data, &block)
        end
      end
    rescue ShutdownSignal
      # Shutting down
      @logger.warn('[LogCourierServer] Server shutting down') unless @logger.nil?
    rescue => e
      # Some other unknown problem
      @logger.warn("[LogCourierServer] Unknown error: #{e}") unless @logger.nil?
      @logger.debug("[LogCourierServer] #{e.backtrace}: #{e.message} (#{e.class})") unless @logger.nil? || !@logger.debug?
    ensure
      @socket.close
      @context.terminate
    end

    def recv(data)
      if data.length < 8
        @logger.warn '[LogCourierServer] Invalid message: not enough data' unless @logger.nil?
        return
      end

      # Unpack the header
      signature, length = data.unpack('A4N')

      # Verify length
      if data.length - 8 != length
        @logger.warn "[LogCourierServer] Invalid message: data has invalid length (#{data.length - 8} != #{length})" unless @logger.nil?
        return
      end

      # Yield the parts
      yield signature, data[8, length], self
    end

    def send(signature, message)
      reset_timeout
      data = signature + [message.length].pack('N') + message
      loop do
        # Try to send a message but never block
        rc = @socket.send_string(data, ZMQ::DONTWAIT)
        break if ZMQ::Util.resultcode_ok?(rc)
        if ZMQ::Util.errno != ZMQ::EAGAIN
          @logger.warn "[LogCourierServer] Message send failed: #{ZMQ::Util.error_string}" unless @logger.nil?
          raise Timeout::Error
        end

        # Wait for send to become available, handling timeouts
        @poller.deregister @socket
        @poller.register_writable @socket
        raise Timeout::Error if @poller.poll(()@timeout - Time.now.to_i) * 1_000) == 0
      end
    end

    def reset_timeout()
      # TODO: Make configurable?
      @timeout = Time.now.to_i + 1_800
    end
  end
end
