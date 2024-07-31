# frozen_string_literal: true

require 'csv'
require 'json'
require 'byebug'

def wta_csv_filename
  csv_dir = 'input'
  year = '2022-23'
  tab = 'InvoiceOverdues'
  "#{csv_dir}/#{year} WTA Player Payments - #{tab}.csv"
end

def wta_required_headers
  %w[
    player_first
    player_last
    payer_first
    payer_last
    payer_email
    payer_xero_contact_id
  ]
end

def account_code_by(grade)
  grade = grade.downcase.tr('_', '').tr(' ', '')
  hsh = {
    '216': ['juniors'],
    '244': %w[youths u16b u16g u16x u18b u18g u18x],
    '204': %w[seniors om ow ox 40m 40mens openmens openwomens openmixed]
  }
  acnt_code = hsh.select { |_k, v| v.include?(grade) }.keys[0]
  return "error: Grade doesn't match any account code. Grade: #{grade}" unless acnt_code

  acnt_code.to_s
end

def get_contact_by_email(xero_client, email)
  puts "get_contact_by_email for email: #{email}"
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']

  opts = {
    summaryOnly: true,
    where: {
      email_address: ['==', email]
    }
  }

  existing_contacts = xero_client.accounting_api.get_contacts(tenant_id, opts).contacts
  existing_contacts[0]
end

def create_contact(xero_client, first_name, last_name, email)
  if first_name.nil? || last_name.nil? || email.nil?
    puts "Cannot create_contact if any of first_name (#{first_name}), last_name (#{last_name}), email (#{email}) are empty"
    return [false, nil, 'Cannot create_contact due to errors']
  end

  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']

  contacts = {
    name: "#{first_name} #{last_name}".strip,
    first_name: first_name,
    last_name: last_name,
    email_address: email
  }

  new_contacts = xero_client.accounting_api.create_contacts(tenant_id, contacts).contacts
  [true, new_contacts[0]]
end

def get_invoice(xero_client, invoice_id)
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']

  opts = {}

  xero_client.accounting_api.get_invoice(tenant_id, invoice_id, opts).invoices[0]
end

def get_invoices_by(xero_client, xero_contact_id, reference)
  puts "get_invoices_by for reference: #{reference}"

  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']

  opts = {
    where: {
      'Contact.ContactID': ['=', xero_contact_id],
      reference: ['=', reference],
      status: ['!=', 'DELETED']
    }
  }

  xero_client.accounting_api.get_invoices(tenant_id, opts).invoices
end

def get_invoices_btwn_dates(xero_client, from, to = DateTime.now)
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']

  opts = {
    where: {
      date: from..to,
      type: ['=', 'ACCREC'],
      status: ['=', 'AUTHORISED']
    }
  }

  xero_client.accounting_api.get_invoices(tenant_id, opts).invoices
end

def create_invoice(xero_client, xero_contact_id, date, due_date, reference, line_items)
  xero_client.set_token_set(session[:token_set])
  xero_tenant_id = xero_client.connections[0]['tenantId']

  invoice = {
    type: XeroRuby::Accounting::Invoice::ACCREC,
    status: XeroRuby::Accounting::Invoice::DRAFT,
    contact: { contact_id: xero_contact_id },
    date: date,
    due_date: due_date,
    reference: reference,
    line_amount_types: XeroRuby::Accounting::LineAmountTypes::INCLUSIVE,
    line_items: line_items
  }

  invoices = { invoices: [invoice] }

  opts = {
    summarize_errors: true,
    unitdp: 2
  }

  new_invoices = xero_client.accounting_api.create_invoices(xero_tenant_id, invoices, opts)

  if new_invoices.invoices.length > 1
    raise "Only expected to create a single invoice but created many. new_invoices: #{new_invoices}"
  end

  new_invoices.invoices[0]
end

def get_contacts_with_email(xero_client)
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']
  opts = {
    summaryOnly: true,
    where: {
      email_address: ['!=', nil]
    }
  }
  xero_client.accounting_api.get_contacts(tenant_id, opts).contacts
end

def credit_invoice(xero_client, invoice, date, account_code)
  xero_client.set_token_set(session[:token_set])
  tenant_id = xero_client.connections[0]['tenantId']

  line_items = [
    {
      description: invoice.line_items[0].description,
      quantity: invoice.line_items[0].quantity,
      unit_amount: invoice.amount_due,
      account_code: account_code # normally '491' bad debt code
    }
  ]

  credit = {
    type: XeroRuby::Accounting::CreditNote::ACCRECCREDIT,
    status: XeroRuby::Accounting::CreditNote::AUTHORISED,
    contact: { contact_id: invoice.contact.contact_id },
    date: date,
    reference: invoice.reference,
    line_amount_types: XeroRuby::Accounting::LineAmountTypes::INCLUSIVE,
    line_items: line_items
  }

  credits = { credit_notes: [credit] }

  opts = {
    summarize_errors: true,
    unitdp: 2
  }

  credit_note = xero_client.accounting_api.create_credit_notes(tenant_id, credits, opts).credit_notes[0]
  # puts credit_note

  allocation = { amount: invoice.amount_due, invoice: { invoice_id: invoice.invoice_id } }
  allocations = { allocations: [allocation] }

  xero_client.accounting_api.create_credit_note_allocation(tenant_id, credit_note.credit_note_id, allocations, opts)
end
