# frozen_string_literal: true

module Arke::Exchange
  class Binance < Base
    attr_reader :last_update_id
    attr_accessor :orderbook

    def initialize(opts)
      super
      @host ||= "https://api.binance.com"
      @client = ::Binance::Client::REST.new(api_key: @api_key, secret_key: @secret, adapter: @adapter)
      @min_notional = {}
      @min_quantity = {}
      @amount_precision = {}
    end

    def ws_connect_public
      streams = @markets_to_listen.map {|market| "#{market.downcase}@aggTrade.b10" }.join("/")
      @ws_url = "wss://stream.binance.com:9443/stream?streams=#{streams}"
      ws_connect(:public)
    end

    def ws_read_public_message(msg)
      d = msg["data"]
      case d["e"]
      # "m": true, Is the buyer the market maker?
      # in API we expose taker_type
      when "aggTrade"
        trade = ::Arke::PublicTrade.new
        trade.id = d["a"]
        trade.market = d["s"]
        trade.exchange = "binance"
        trade.taker_type = d["m"] ? "sell" : "buy"
        trade.amount = d["q"].to_d
        trade.price = d["p"].to_d
        trade.total = trade.total
        trade.created_at = d["T"]
      when "trade"
        trade = ::Arke::PublicTrade.new
        trade.id = d["t"]
        trade.market = d["s"]
        trade.exchange = "binance"
        trade.taker_type = d["m"] ? "sell" : "buy"
        trade.amount = d["q"].to_d
        trade.price = d["p"].to_d
        trade.total = trade.total
        trade.created_at = d["T"]
      else
        raise "Unsupported event type #{d['e']}"
      end
      notify_public_trade(trade)
    end

    def build_order(data, side)
      Arke::Order.new(
        @market,
        data[0].to_f,
        data[1].to_f,
        side
      )
    end

    def new_trade(data)
      taker_type = data["b"] > data["a"] ? :buy : :sell
      market = data["s"]
      pm_id = @platform_markets[market]

      trade = Trade.new(
        price:              data["p"],
        amount:             data["q"],
        platform_market_id: pm_id,
        taker_type:         taker_type
      )
      @opts[:on_trade]&.call(trade, market)
    end

    def update_orderbook(market)
      orderbook = Arke::Orderbook::Orderbook.new(market)
      limit = @opts["limit"] || 1000
      snapshot = @client.depth(symbol: market.upcase, limit: limit)
      Array(snapshot["bids"]).each do |order|
        orderbook.update(
          build_order(order, :buy)
        )
      end
      Array(snapshot["asks"]).each do |order|
        orderbook.update(
          build_order(order, :sell)
        )
      end
      orderbook
    end

    def markets
      return @markets if @markets.present?

      @client.exchange_info["symbols"]
             .filter {|s| s["status"] == "TRADING" }
             .map {|s| s["symbol"] }
    end

    def get_amount(order)
      min_notional = @min_notional[order.market] ||= get_min_notional(order.market)
      amount_precision = @amount_precision[order.market] ||= get_amount_precision(order.market)
      notional = order.price * order.amount
      amount = if notional > min_notional
                 order.amount
               else
                 (min_notional / order.price).ceil(amount_precision)
               end
      "%0.#{amount_precision.to_i}f" % amount
    end

    def create_order(order)
      amount = get_amount(order)
      return if amount.to_f.zero?
      raise "ACCOUNT:#{id} price_s is nil" if order.price_s.nil? && order.type == "limit"

      raw_order = {
        symbol:        order.market.upcase,
        side:          order.side.upcase,
        type:          "LIMIT",
        time_in_force: "GTC",
        quantity:      "%f" % amount,
        price:         order.price_s,
      }
      logger.debug { "Binance order: #{raw_order}" }
      @client.create_order!(raw_order)
    end

    def get_balances
      balances = @client.account_info["balances"]
      balances.map do |data|
        {
          "currency" => data["asset"],
          "free"     => data["free"].to_f,
          "locked"   => data["locked"].to_f,
          "total"    => data["free"].to_f + data["locked"].to_f,
        }
      end
    end

    def fetch_openorders(market)
      @client.open_orders(symbol: market).map do |o|
        remaining_volume = o["origQty"].to_f - o["executedQty"].to_f
        Arke::Order.new(
          o["symbol"],
          o["price"].to_f,
          remaining_volume,
          o["side"].downcase.to_sym,
          o["type"].downcase.to_sym,
          o["orderId"]
        )
      end
    end

    def get_amount_precision(market)
      min_quantity = @min_quantity[market] ||= get_min_quantity(market)
      value_precision(min_quantity)
    end

    def get_symbol_info(market)
      @exchange_info ||= @client.exchange_info["symbols"]
      @exchange_info.find {|s| s["symbol"] == market }
    end

    def get_symbol_filter(market, filter)
      info = get_symbol_info(market)
      raise "#{market} not found" unless info

      info["filters"].find {|f| f["filterType"] == filter }
    end

    def get_min_quantity(market)
      get_symbol_filter(market, "LOT_SIZE")["minQty"].to_f
    end

    def get_min_notional(market)
      get_symbol_filter(market, "MIN_NOTIONAL")["minNotional"].to_f
    end

    def market_config(market)
      info = get_symbol_info(market)
      raise "#{market} not found" unless info

      price_filter = get_symbol_filter(market, "PRICE_FILTER")

      {
        "id"               => info.fetch("symbol"),
        "base_unit"        => info.fetch("baseAsset"),
        "quote_unit"       => info.fetch("quoteAsset"),
        "min_price"        => price_filter&.fetch("minPrice").to_f,
        "max_price"        => price_filter&.fetch("maxPrice").to_f,
        "min_amount"       => get_min_quantity(market),
        "amount_precision" => get_amount_precision(market),
        "price_precision"  => info.fetch("quotePrecision")
      }
    end
  end
end
