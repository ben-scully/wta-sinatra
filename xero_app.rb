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
  puts <<~HEREDOC
    ============================
    BEFORE:
    session[:token_set]:
    #{session[:token_set]}

  HEREDOC
  puts
  if request.path_info == '/auth/callback'
    puts <<~HEREDOC
      ----------------------------
      PASS:
      request.path_info:
      #{request.path_info}

    HEREDOC
    puts
    pass
  end

  if request.path_info != '/' && session[:token_set].nil?
    puts <<~HEREDOC
      ----------------------------
      REDIRECT:
      request.path_info:
      #{request.path_info}

      ----------------------------
      session[:token_set]:
      #{session[:token_set]}

    HEREDOC
    puts
    redirect to('/')
  end
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

  changes_detected = false
  dryrun = true
  dryrun = false if confirmed?

  @rows.each do |row|
    payer_xero_contact_id = row['payer_xero_contact_id']
    missing_email_msg = 'MISSING email'
    dryrun_msg = 'DRYRUN: to be created'
    error_msg = 'error'

    # already a value BUT it's not dryrun_msg or missing_email_msg AND it's doesn't include error_msg
    next if payer_xero_contact_id &&
            payer_xero_contact_id != dryrun_msg &&
            payer_xero_contact_id != missing_email_msg &&
            !payer_xero_contact_id.include?(error_msg)

    puts
    puts
    puts "===================="

    changes_detected = true

    unless row['payer_email']
      puts <<~HEREDOC
        CSV: missing payer_email for player_first: #{row['player_first']}
      HEREDOC
      row['payer_xero_contact_id'] = missing_email_msg
      next
    end

    puts <<~HEREDOC
      CSV: missing contact_id for #{row['payer_email']}
    HEREDOC

    begin
      existing_contact = false

      if row['payer_xero_contact_id'] == dryrun_msg
        puts <<~HEREDOC
          FYI: this 2nd time running in dryrun mode, don't ping Xero API #{row['payer_email']}
        HEREDOC
      else
        existing_contact = get_contact_by_email(xero_client, row['payer_email'])
      end

      if existing_contact
        puts <<~HEREDOC
          API: there is a xero_contact_id for #{row['payer_email']} setting 'payer_xero_contact_id' (#{existing_contact.contact_id}) in CSV
        HEREDOC

        row['payer_xero_contact_id'] = existing_contact.contact_id
        next
      end

      puts <<~HEREDOC
        API: there is NO xero_contact_id for #{row['payer_email']} creating new Xero Contact
      HEREDOC

      if dryrun
        puts <<~HEREDOC
          FYI: this a dryrun for  #{row['payer_email']}. Set 'payer_xero_contact_id' to #{dryrun_msg}
        HEREDOC
        row['payer_xero_contact_id'] = dryrun_msg
      else
        firstname = row['payer_first']
        lastname = row['payer_last']

        if !firstname || !lastname
          puts <<~HEREDOC
            CSV: missing payer names, will try to use player names. Email: #{row['payer_email']}
          HEREDOC
          firstname = row['player_first']
          lastname = row['player_last']
        end

        result, new_contact = create_contact(
          xero_client,
          firstname,
          lastname,
          row['payer_email']
        )

        if result
          puts <<~HEREDOC
            new_contact class is: #{new_contact.class}
          HEREDOC

          puts <<~HEREDOC
            a new Xero Contact has been created for #{row['payer_email']}
            setting 'payer_xero_contact_id' (#{new_contact.contact_id}) in CSV
          HEREDOC

          row['payer_xero_contact_id'] = new_contact.contact_id
        else
          row['payer_xero_contact_id'] = new_contact
        end
      end
    rescue XeroRuby::ApiError => e
      puts e
      row['payer_xero_contact_id'] = e.message
      next
    end
  end

  hash_as_csv(wta_csv_filename, @headers, @rows) if changes_detected

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

get '/invoices-filtered' do
  from = Date.new(2020, 4, 1)
  to = Date.new(2021, 3, 31)
  @rows = get_invoices_btwn_dates(xero_client, from, to)

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

def confirmed?(*args)
  return true if params['confirmed'] == 'true'

  @errors = [
    "params: #{params}",
    "*args: #{args}"
  ]
  false
end

get '/invoices-credit' do
  from = Date.new(2020, 4, 1)
  to = Date.new(2021, 3, 31)

  return haml :home unless confirmed?(from, to)

  @rows = get_invoices_btwn_dates(xero_client, from, to)

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

    date = Date.new(2022, 3, 31)

    account_code = '491' # bad debt code
    credit_invoice(xero_client, invoice, date, account_code)
  end

  haml :invoices
end

get '/invoices-create-missing' do
  @headers, @rows = csv_as_hash(wta_csv_filename, wta_required_headers)

  changes_detected = false
  dryrun = true
  dryrun = false if confirmed?

  @rows.each do |row|
    next if row['xero_invoice_id']
    raise "missing 'payer_xero_contact_id'" unless row['payer_xero_contact_id']

    changes_detected = true

    puts <<~HEREDOC
      ============================================================
      CSV: missing xero_invoice_id for #{row['payer_email']}  #{row['payer_xero_contact_id']}
    HEREDOC
    puts

    begin
      team = row['team']
      reference = "#{row['season']} #{row['event']} #{team} #{row['player_first']} #{row['player_last']}"
      existing_invoices = get_invoices_by(xero_client, row['payer_xero_contact_id'], reference)

      if existing_invoices.length > 1
        row['xero_invoice_id'] = 'More than 1 invoice detected. Review before continuing'
        next
      end

      if existing_invoices.length == 1
        puts <<~HEREDOC
          API: there is a xero_invoice_id for #{row['amount']} #{[row['season'], row['event'], team].join(', ')}
          setting 'xero_invoice_id' (#{existing_invoices[0].invoice_id}) in CSV
        HEREDOC
        puts

        row['xero_invoice_id'] = existing_invoices[0].invoice_id
        next
      end

      puts <<~HEREDOC
        API: there is NO xero_invoice_id for #{row['payer_email']} creating new Xero Invoice
      HEREDOC
      puts

      invoice_date = Date.parse(row['date']).strftime('%Y-%m-%d')
      invoice_due_date = Date.parse(row['due_date']).strftime('%Y-%m-%d')

      # Remained of your non-refundable commitment fee.
      team = row['team']
      description = <<~HEREDOC
        #{row['player_first']} #{row['player_last']} #{row['season']} #{row['event']} #{team}
        #{raise 'update this description'}
      HEREDOC

      line_items = [
        {
          description: description,
          quantity: 1.0,
          unit_amount: row['amount'].to_f,
          account_code: account_code_by(team)
        }
      ]

      if dryrun
        row['xero_invoice_id'] = 'DRYRUN: to be created'
      else
        new_invoice = create_invoice(
          xero_client,
          row['payer_xero_contact_id'],
          invoice_date,
          invoice_due_date,
          reference,
          line_items
        )

        puts <<~HEREDOC
          API: a new Xero Invoice has been created for #{row['payer_email']}
          setting 'xero_invoice_id' (#{new_invoice.invoice_id}) in CSV
        HEREDOC
        puts

        row['xero_invoice_id'] = new_invoice.invoice_id
      end
    rescue XeroRuby::ApiError => e
      row['xero_invoice_id'] = e.message
      next
    end
  end

  hash_as_csv(wta_csv_filename, @headers, @rows) if changes_detected

  haml :csv
end
