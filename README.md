# wta-sinatra

```bash
bundle exec ruby xero_app.rb
```

## Checks

### get '/auth/callback'
...

### get '/add-connection'
...

### get '/refresh-token'
...

### get '/disconnect'
...

### get '/connections'
...

### get '/contacts'
- `xero_service` methods in use?
  - xero_service.contacts
- working?
  - YES

### get '/contacts-dup-detection'
- `xero_service` methods in use?
  - xero_service.contacts_with_duplicates
- working?
  - YES

### get '/invoices'
- `xero_service` methods in use?
  - xero_service.invoices
- working?
  - YES

### get '/invoices-filtered'
- `xero_service` methods in use?
  - xero_service.invoices_btwn_dates
- working?
  - YES

### get '/invoices-credit-filtered'
- `xero_service` methods in use?
  - xero_service.invoices_btwn_dates
  - xero_service.credit_invoices
- working?
  - YES

## Contacts
xero_service
  - contacts
  - contacts_with_duplicates
xero_db
  - ??

## Invoices
xero_service
  - invoices (GET)
xero_db
  - previous `get_invoices` deleted
