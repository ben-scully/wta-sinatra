# frozen_string_literal: true

require 'csv'
require 'json'
require 'byebug'

# require 'yaml'
# write_filename = 'input/temp_dup_detection.yaml'
# File.open(write_filename, "w") { |file| file.write(contacts_with_email.to_yaml) }

# read_filename = 'input/temp_dup_detection_copy.yaml'
# contacts_with_email = YAML.load(File.read(read_filename))

class String
  def snakecase
    #gsub(/::/, '/').
    gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2')
      .gsub(/([a-z\d])([A-Z])/,'\1_\2')
      .tr('-', '_')
      .gsub(/\s/, '_')
      .gsub(/__+/, '_')
      .downcase
  end
end

def csv_as_hash(filename, required_headers)
  csv = CSV.read(filename)
  headers = csv.shift
  headers = headers&.map(&:snakecase)

  missing = required_headers - headers
  unless missing.empty?
    raise <<~HEREDOC
      \n
      these headers are missing: #{missing}

      from required_headers:     #{required_headers}
    HEREDOC
  end

  rows = csv.map do |row|
    row.map.with_index.each_with_object({}) do |(col, idx), obj|
      header = headers[idx]
      obj[header] = col
      obj
    end
  end

  [headers, rows]
end

def hash_as_csv(filename, headers, rows_as_hash)
  puts "Starting 'hash_as_csv' for filename: #{filename}"
  rows_as_arr = rows_as_hash.map do |row|
    headers.map do |header|
      row[header]
    end
  end

  headers_plus_rows = rows_as_arr.unshift(headers)

  require 'csv'
  CSV.open(filename, 'w') do |csv|
    headers_plus_rows.each do |row|
      csv << row
    end
  end
  puts "Completed 'hash_as_csv' for filename: #{filename}"
end
