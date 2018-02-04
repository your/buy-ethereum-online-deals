#!/usr/bin/env ruby

require 'json'
require 'mailgun'
require 'open-uri'

MAX_ADS = 100

MAILGUN_API_KEY = ''.freeze
MAILGUN_DOMAIN  = ''.freeze
NOTIFICATION_EMAIL = ''.freeze

STDOUT.sync = true

def send_email(subject, txt, recipient = NOTIFICATION_EMAIL, sender = recipient)
  mg_client = Mailgun::Client.new(MAILGUN_API_KEY)

  message_params = {
    from: sender,
    to: recipient,
    subject: subject,
    text: txt
  }

  mg_client.send_message(MAILGUN_DOMAIN, message_params)
end

# :nodoc:
class CurrencyConverter
  attr_reader :currency_conversion_rates

  def initialize(currencies:, base: 'USD')
    @currency_conversion_rates = {}
    @currencies = currencies || raise('I need currencies to convert.')
    @base = base
  end

  def run
    # Max 2 pairs is supported for the free version of currencyconverterapi.com
    currency_pairs.each_slice(2).each do |grouped_pairs|
      query = grouped_pairs.join(',')

      response = fetch_response(query)
      extract_conversion_rate(response)
    end
  end

  private

  API_ENDPOINT = 'https://free.currencyconverterapi.com/api/v5/convert'.freeze
  private_constant :API_ENDPOINT

  attr_reader :currencies, :base

  def currency_pairs
    currencies.map do |currency|
      "#{currency}_#{base}"
    end
  end

  def fetch_response(query)
    url = "#{API_ENDPOINT}?q=#{query}"
    JSON.parse(open(url).read, symbolize_names: true)
  end

  def extract_conversion_rate(response)
    response[:results].each_pair do |(_, currency_pair_conversion)|
      base_currency = currency_pair_conversion[:fr]
      conversion_rate = currency_pair_conversion[:val]

      currency_conversion_rates[base_currency] = conversion_rate
    end
  end
end

# :nodoc:
class LocalEthereumAPIFetcher
  attr_reader :payment_ids, :payment_methods

  # payment_ids:
  # 2: Bank transfer
  # 4: PayPal
  # 5: International wire
  def initialize(payment_ids: [2, 4, 5])
    @payment_ids = payment_ids
    @cursor = 0
  end

  def run
    reset_results
    fetch_payment_methods

    until end?
      pages << next_page
      update_cursor
    end

    reset_cursor
  end

  def offers
    return @offers if @offers.any?

    @offers = pages.flat_map do |page|
      page[:offers]
    end

    @offers = filter_offers_by_payment_method_id(payment_ids)
  end

  def currencies
    @currencies = offers.map do |offer|
      offer[:local_currency_code].upcase
    end.uniq
  end

  private

  SETTINGS_ENDPOINT = 'https://api.localethereum.com/v1/settings'.freeze
  OFFERS_ENDPOINT = 'https://api.localethereum.com/v1/offers/find'.freeze
  private_constant :SETTINGS_ENDPOINT, :OFFERS_ENDPOINT

  attr_reader :cursor, :pages, :page

  def reset_results
    @pages = []
    @offers = []
    @currencies = []
    @payment_methods = []
  end

  def reset_cursor
    @cursor = 0
  end

  def end?
    cursor.nil?
  end

  def update_cursor
    @cursor = page[:next]
  end

  def fetch_url(url)
    puts "Fetching #{url}..."
    JSON.parse(open(url).read, symbolize_names: true)
  end

  def next_page
    url = "#{OFFERS_ENDPOINT}?sort_by=price&offer_type=sell&after=#{cursor}"
    @page = fetch_url(url)
  end

  def fetch_payment_methods
    url = SETTINGS_ENDPOINT
    @payment_methods = fetch_url(url)[:payment_methods]
  end

  def filter_offers_by_payment_method_id(payment_ids)
    offers.select do |offer|
      payment_ids.include?(offer[:payment_method_id])
    end
  end
end

fetcher = LocalEthereumAPIFetcher.new

puts
puts 'Fetching data...'
puts

fetcher.run

puts '...done.'

all_offers = fetcher.offers
all_currencies = fetcher.currencies
all_payment_methods = fetcher.payment_methods

converter = CurrencyConverter.new(currencies: all_currencies)

puts
puts 'Fetching currency exchange rates...'

converter.run

puts '...done.'

all_currency_conversion_rates = converter.currency_conversion_rates

puts
puts 'Elaborating results...'

all_offers.each do |offer|
  currency = offer[:local_currency_code]
  amount_including_taker_fee = offer[:price][:amount_including_taker_fee]

  usd_rate = all_currency_conversion_rates[currency]
  price_conversion = (amount_including_taker_fee * usd_rate).to_f.round(2)

  payment_method_name = all_payment_methods.find do |payment_method|
    payment_method[:id] == offer[:payment_method_id]
  end[:name]

  offer[:price_usd] = price_conversion
  offer[:payment_method_name] = payment_method_name
  offer[:link] = "https://localethereum.com/offer/#{offer[:id]}"
end

all_offers.sort_by! { |offer| offer[:price_usd] }

results = "\n"
results += "Top #{MAX_ADS} cheapest buy-ethereum-online deals:\n\n"

results += format "%-15s | %-20s | %-10s | %s\n",
                  'Price/ETH (USD)',
                  'Payment Method',
                  'Country',
                  'Link'

results += "#{'-' * 90}\n"

all_offers.first(MAX_ADS).each do |ad|
  results += format "%-15s | %-20s | %-10s | %s\n",
                    ad[:price_usd],
                    ad[:payment_method_name],
                    ad[:city][:country_code],
                    ad[:link]
end

results += "\n"

puts results

unless NOTIFICATION_EMAIL.empty?
  send_email(
    "Top #{MAX_ADS} cheapest buy-ethereum-online deals",
    results,
    NOTIFICATION_EMAIL
  )
  puts "Sent notification email to #{NOTIFICATION_EMAIL}."
end
