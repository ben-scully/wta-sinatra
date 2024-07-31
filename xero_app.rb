# This is an example app that provides a dashboard to make some example
# calls to the Xero API actions after authorising the app via OAuth 2.0.

require 'sinatra'
require 'sinatra/reloader' if development?
require 'xero-ruby'
require 'securerandom'
require 'dotenv/load'
require 'jwt'
require 'pp'
require 'byebug' if development?
require_relative 'helpers/helpers'
require_relative 'helpers/xero_db'

enable :sessions
set :session_secret, '328479283uf923fu8932fu923uf9832f23f232'
use Rack::Session::Pool
set :haml, format: :html5

# Setup the credentials we use to connect to the XeroAPI
CREDENTIALS ||= {
  client_id: ENV['CLIENT_ID'],
  client_secret: ENV['CLIENT_SECRET'],
  redirect_uri: ENV['REDIRECT_URI'],
  scopes: ENV['SCOPES']
}.freeze

DRYRUN = 'DRYRUN'.freeze
MISSING = 'MISSING'.freeze
ERROR = 'error'.freeze

# We initialise an instance of the Xero API Client here so we can make calls
# to the API later. Memoization `||=`` will return a previously initialized client.
helpers do
  def xero_client
    @xero_client ||= XeroRuby::ApiClient.new(credentials: CREDENTIALS)
  end
end

# Before every request, we need to check that we have
# a session.
# If we don't, then redirect to the index page to prompt
# the user to go through the OAuth 2.0 authorization flow.
before do
  if request.path_info == '/auth/callback'
    pass
  end

  if request.path_info != '/' && session[:token_set].nil?
    redirect to('/')
  end
end

def dryrun?(*args)
  return false if params['confirmed'] == 'true'

  @errors = [
    "params: #{params}",
    "*args: #{args}"
  ]
  true
end

# On the homepage, we need to define a few variables that are used by the
# 'home.haml' layout file in the 'views/' directory.
get '/' do
  @token_set = session[:token_set]
  @auth_url = xero_client.authorization_url

  @access_token = JWT.decode @token_set['access_token'], nil, false if @token_set && @token_set['access_token']
  @id_token = JWT.decode @token_set['id_token'], nil, false if @token_set && @token_set['id_token']

  haml :home
end

# This endpoint is used to handle the redirect from the
# Xero OAuth 2.0 authorisation process
get '/auth/callback' do
  @token_set = xero_client.get_token_set_from_callback(params)
  session[:token_set] = @token_set
  redirect to('/')
end

# This endpoint redirects the user to connect another
# Xero organisation.
get '/add-connection' do
  @auth_url = xero_client.authorization_url
  redirect to(@auth_url)
end

# This endpoint is here specifically to refresh the token at will.
# In a production setting this will most likely happen as part of a background job,
# not something the user has to click.
get '/refresh-token' do
  @token_set = xero_client.refresh_token_set(session[:token_set])
  session[:token_set] = @token_set

  # Set some variables for the 'refresh_token.haml' view.
  @access_token = JWT.decode @token_set['access_token'], nil, false if @token_set && @token_set['access_token']
  @id_token = JWT.decode @token_set['id_token'], nil, false if @token_set && @token_set['id_token']

  haml :refresh_token
end

# This endpoint allows the user to explicitly disconnect the app from
# their Xero organisation.
# Note: At this point in time, it assumes that you have a single organisation
# connected.
get '/disconnect' do
  xero_client.set_token_set(session[:token_set])
  # This will disconnect the first organisation that appears in the xero_client.connections array.
  xero_client.disconnect(xero_client.connections[0]['id'])
  @connections = xero_client.connections

  haml :disconnect
end

# This endpoint will list the Xero organisations that your app is authorized to access.
get '/connections' do
  xero_client.set_token_set(session[:token_set])
  @connections = xero_client.connections

  haml :connections
end

# This endpoint shows contacts data via the 'contacts.haml' view.
get '/contacts' do
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']
  opts = { summaryOnly: true }
  @contacts = xero_client.accounting_api.get_contacts(tenant_id, opts).contacts

  haml :contacts
end

get '/contacts-dup-detection' do
  contacts_with_email = get_contacts_with_email(xero_client)

  grouped_by_email = contacts_with_email.group_by(&:email_address)
  # {
  #   "1@email.com": [Contact1,Contact2,Contact3],
  #   "2@email.com": [Contact1,Contact2],
  #   "3@email.com": [Contact1,Contact2,Contact3,Contact4]
  # }

  # reduce to contacts with 2+ of same email
  duped_emails = grouped_by_email.select { |_k, v| v.count > 1 }

  @headers = %w[
    email_address
    contact_id
    contact_status
    name
    first_name
    last_name
    updated_date_utc
  ]

  # convert data from Ruby objects to Ruby hashes, the format requried for 'haml :csv'
  hashed_contacts = duped_emails.map do |_email, contacts|
    contacts.map do |contact|
      @headers.each_with_object({}) do |header, hsh|
        hsh[header] = contact.instance_variable_get("@#{header}")
        hsh
      end
    end
  end

  @rows = hashed_contacts.flatten

  haml :csv
end

get '/contacts-create-missing' do
  @headers, @rows = csv_as_hash(wta_csv_filename, wta_required_headers)

  # determine if this is a dry run
  dryrun = dryrun?

  @rows.each do |row|
    puts
    puts
    puts "===================="

    # Validate
    unless row['payer_email']
      puts "CSV: missing payer_email for player_first: #{row['player_first']}"
      row['payer_xero_contact_id'] = 'MISSING email'
      next
    end

    # Skip this row if it's already been processed correctly
    payer_xero_contact_id = row['payer_xero_contact_id']
    next if payer_xero_contact_id &&
            !payer_xero_contact_id.include?(DRYRUN) &&
            !payer_xero_contact_id.include?(MISSING) &&
            !payer_xero_contact_id.include?(ERROR)

    puts "CSV: missing contact_id for #{row['payer_email']}"

    begin
      existing_contact = false

      if row['payer_xero_contact_id']&.include?(DRYRUN)
        puts "FYI: this 2nd time running in DRYRUN mode, don't ping Xero API #{row['payer_email']}"
        next
      else
        existing_contact = get_contact_by_email(xero_client, row['payer_email'])
      end

      if dryrun
        dryrun_msg = 'DRYRUN: to be created'
        puts "FYI: this a DRYRUN for  #{row['payer_email']}. Set 'payer_xero_contact_id' to #{dryrun_msg}"
        row['payer_xero_contact_id'] = dryrun_msg
        next
      end

      if existing_contact
        puts "API: existing xero_contact_id for #{row['payer_email']}. Set 'payer_xero_contact_id' (#{existing_contact.contact_id}) in CSV"
        row['payer_xero_contact_id'] = existing_contact.contact_id
        next
      end

      puts "API: there is NO existing xero_contact_id for #{row['payer_email']} need to create new Xero Contact"

      firstname = row['payer_first']
      lastname = row['payer_last']

      if !firstname || !lastname
        puts "CSV: missing payer names, will try to use player names. Email: #{row['payer_email']}"
        firstname = row['player_first']
        lastname = row['player_last']
      end

      result, new_contact, error_msg = create_contact(
        xero_client,
        firstname,
        lastname,
        row['payer_email']
      )

      if result
        puts "new Xero Contact has been created for #{row['payer_email']}. Set 'payer_xero_contact_id' (#{new_contact.contact_id}) in CSV"
        row['payer_xero_contact_id'] = new_contact.contact_id
      else
        row['payer_xero_contact_id'] = error_msg
      end
    rescue XeroRuby::ApiError => e
      puts e
      row['payer_xero_contact_id'] = e.message
      next
    end
  end

  hash_as_csv(wta_csv_filename, @headers, @rows)

  haml :csv
end

# This endpoint shows invoice data via the 'invoices.haml' view.
get '/invoices' do
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']
  @rows = xero_client.accounting_api.get_invoices(tenant_id).invoices
  @headers = @rows.first.to_attributes.keys unless @rows.empty?

  haml :invoices
end

# Use these vars in both '/invoices-filtered' & '/invoices-credit' so i don't
# look at result of '/invoices-filtered' and think that is what will be credited in '/invoices-credit'
invoice_filter_from = Date.new(2021, 4, 1)
invoice_filter_to = Date.new(2022, 3, 31)
credit_date = invoice_filter_to.next_year

get '/invoices-filtered' do
  @rows = get_invoices_btwn_dates(xero_client, invoice_filter_from, invoice_filter_to)

  @headers = [
    'type',
    ['contact', 'name'],
    'date',
    'due_date',
    'invoice_number',
    'reference',
    'total',
    'amount_due',
    'amount_paid',
    'amount_credited',
    'credit_notes'
  ]

  haml :invoices
end

get '/invoices-credit' do
  return haml :home unless dryrun?(invoice_filter_from, invoice_filter_to)

  @rows = get_invoices_btwn_dates(xero_client, invoice_filter_from, invoice_filter_to)

  @headers = [
    'type',
    ['contact', 'name'],
    'date',
    'due_date',
    'invoice_number',
    'reference',
    'total',
    'amount_due',
    'amount_paid',
    'amount_credited',
    'credit_notes'
  ]

  @rows.each do |row|
    invoice = get_invoice(xero_client, row.invoice_id)
    account_code = '491' # bad debt code
    credit_invoice(xero_client, invoice, credit_date, account_code)
  end

  haml :invoices
end

get '/invoices-create-missing' do
  @headers, @rows = csv_as_hash(wta_csv_filename, wta_required_headers)

  # determine if this is a dry run
  dryrun = dryrun?

  @rows.each do |row|
    puts
    puts
    puts "===================="

    # Validate
    unless row['payer_xero_contact_id']
      puts "CSV: missing 'payer_xero_contact_id' for #{row['payer_email']}"
      row['xero_invoice_id'] = 'MISSING payer_xero_contact_id'
      next
    end

    # Skip this row if it's already been processed correctly
    xero_invoice_id = row['xero_invoice_id']
    next if xero_invoice_id &&
            !xero_invoice_id.include?(DRYRUN) &&
            !xero_invoice_id.include?(MISSING) &&
            !xero_invoice_id.include?(ERROR)

    puts "CSV: missing xero_invoice_id for #{row['payer_email']} #{row['payer_xero_contact_id']}"

    begin
      existing_invoices = []

      if dryrun && row['xero_invoice_id']&.include?(DRYRUN)
        puts "FYI: this 2nd time running in DRYRUN mode, don't ping Xero API #{row['payer_email']}"
        next
      else
        team = row['team']
        reference = "#{row['season']} #{row['event']} #{team} #{row['player_first']} #{row['player_last']}"
        existing_invoices = get_invoices_by(xero_client, row['payer_xero_contact_id'], reference)
      end

      if dryrun
        dryrun_msg = 'DRYRUN: to be created'
        puts "FYI: this a DRYRUN for  #{row['payer_email']}. Set 'xero_invoice_id' to #{dryrun_msg}"
        row['xero_invoice_id'] = dryrun_msg
        next
      end

      if existing_invoices.length > 1
        error_msg = 'error: More than 1 invoice detected. Review before continuing'
        puts "ERROR: for #{row['payer_email']}. Set 'xero_invoice_id' to #{error_msg}"
        row['xero_invoice_id'] = 'error: More than 1 invoice detected. Review before continuing'
        next
      end

      if existing_invoices.length == 1
        puts "API: existing xero_invoice_id for #{row['amount']} #{reference}. Set 'xero_invoice_id' (#{existing_invoices[0].invoice_id}) in CSV"
        row['xero_invoice_id'] = existing_invoices[0].invoice_id
        next
      end

      puts "API: there is NO xero_invoice_id for #{row['payer_email']} creating new Xero Invoice"

      invoice_date = Date.parse(row['date']).strftime('%Y-%m-%d')
      invoice_due_date = Date.parse(row['due_date']).strftime('%Y-%m-%d')

      team = row['team']
      description = <<~HEREDOC
        #{row['player_first']} #{row['player_last']} #{row['season']} #{row['event']} #{team}
        #{row['description']}
      HEREDOC

      account_code = account_code_by(team)

      if account_code.include?(ERROR)
        puts "ERROR: #{account_code}"
        row['xero_invoice_id'] = account_code
        next
      end

      line_items = [
        {
          description: description,
          quantity: 1.0,
          unit_amount: row['amount'].to_f,
          account_code: account_code
        }
      ]

      new_invoice = create_invoice(
        xero_client,
        row['payer_xero_contact_id'],
        invoice_date,
        invoice_due_date,
        reference,
        line_items
      )

      puts "API: new Xero Invoice has been created for #{row['payer_email']}. Set 'xero_invoice_id' (#{new_invoice.invoice_id}) in CSV"
      row['xero_invoice_id'] = new_invoice.invoice_id
    rescue XeroRuby::ApiError => e
      puts e
      row['xero_invoice_id'] = e.message
      next
    end
  end

  hash_as_csv(wta_csv_filename, @headers, @rows)

  haml :csv
end
