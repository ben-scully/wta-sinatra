# frozen_string_literal: true

# XeroService
class XeroService
  def initialize(xero_client)
    @xero_client = xero_client
  end

  def contacts(with_an_email: false)
    tenant_id = @xero_client.connections[0]['tenantId']
    opts = { summaryOnly: true }
    if with_an_email
      opts = {
        summaryOnly: true,
        where: {
          email_address: ['!=', nil]
        }
      }
    end
    @xero_client.accounting_api.get_contacts(tenant_id, opts).contacts
  end

  def contacts_with_duplicates
    contacts_with_email = contacts(with_an_email: true)

    grouped_by_email = contacts_with_email.group_by(&:email_address)
    # {
    #   "1@email.com": [Contact1,Contact2,Contact3],
    #   "2@email.com": [Contact1,Contact2],
    #   "3@email.com": [Contact1,Contact2,Contact3,Contact4]
    # }

    # reduce to contacts with 2+ of same email
    duped_emails = grouped_by_email.select { |_k, v| v.count > 1 }

    headers = %w[
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
        headers.each_with_object({}) do |header, hsh|
          hsh[header] = contact.instance_variable_get("@#{header}")
          hsh
        end
      end
    end

    rows = hashed_contacts.flatten
    [headers, rows]
  end

  def invoices
    tenant_id = @xero_client.connections[0]['tenantId']
    rows = @xero_client.accounting_api.get_invoices(tenant_id).invoices
    headers = rows.first.to_attributes.keys unless rows.empty?
    [headers, rows]
  end

  def invoices_btwn_dates(from, to = DateTime.now)
    tenant_id = @xero_client.connections[0]['tenantId']
    opts = {
      where: {
        date: from..to,
        type: ['=', 'ACCREC'],
        status: ['=', 'AUTHORISED']
      }
    }
    headers = [
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
    rows = @xero_client.accounting_api.get_invoices(tenant_id, opts).invoices
    [headers, rows]
  end

  def credit_invoices(invoice_ids, credit_date, account_code = '491')
    # NOTE: '491' == bad debt code
    invoice_ids.each do |invoice_id|
      # NOTE: getting a single invoice has more data, that data's required for credits
      invoice = invoice(invoice_id)
      credit_invoice(invoice, credit_date, account_code)
    end
  end

  private

  # NOTE: getting a single invoice has more data, that data's required for credits
  def invoice(invoice_id)
    tenant_id = @xero_client.connections[0]['tenantId']
    opts = {}
    @xero_client.accounting_api.get_invoice(tenant_id, invoice_id, opts).invoices[0]
  end

  def credit_invoice(invoice, date, account_code)
    tenant_id = @xero_client.connections[0]['tenantId']
    opts = {
      summarize_errors: true,
      unitdp: 2
    }

    ########################################
    # Create credit note
    ########################################
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
    credit_note = @xero_client.accounting_api.create_credit_notes(tenant_id, credits, opts).credit_notes[0]

    ########################################
    # Allocate credit note to invoice
    ########################################
    allocation = { amount: invoice.amount_due, invoice: { invoice_id: invoice.invoice_id } }
    allocations = { allocations: [allocation] }
    @xero_client.accounting_api.create_credit_note_allocation(tenant_id, credit_note.credit_note_id, allocations, opts)
  end
end
