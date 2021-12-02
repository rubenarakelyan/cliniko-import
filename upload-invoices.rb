require 'base64'
require 'faraday'
require 'json'
require 'nokogiri'
require 'sqlite3'
require 'tty-prompt'

# Change the host to match your Cliniko location
API_HOST = "https://api.uk1.cliniko.com".freeze

# Get API key for authentication
prompt = TTY::Prompt.new
api_key = prompt.ask("API key:")

# Set up request headers
# Edit `User-Agent` with your details
HEADERS = {
  "Authorization" => "Basic #{Base64.encode64(api_key + ':')}",
  "Accept" => "application/json",
  "Content-Type" => "application/json",
  "User-Agent" => "Your name (Your email address)"
}

# Set up the database
# This is done by importing a Cliniko CSV patient export into an empty SQLite database
# The important fields are 0 (patient ID) and 28 (reference number, matches the invoice directory structure)
# To create a database:
#  $ sqlite3 db/patients.db
#  sqlite> .mode csv
#  sqlite> .import patients.csv patients
#  sqlite> .exit
db = SQLite3::Database.new("db/patients.db")

# The API connection will be set up the first time an upload is attempted since we don't
# know the S3 endpoint before that
conn = nil

db.execute("select * from patients") do |patient|
  # Ignore any patients without reference numbers
  next if patient[28] == '' || patient[28].nil?

  puts "Finding invoices for patient #{patient[0]}..."

  # Get all invoices for the patient
  Dir.glob("invoices/#{patient[28]}/*.pdf") do |file|
    puts "Uploading #{file}..."

    # Get the presigned URL
    presigned_url = Faraday.get("#{API_HOST}/v1/patients/#{patient[0]}/attachment_presigned_post", nil, HEADERS)
    parsed_response = JSON.parse(presigned_url.body)

    # Upload the file
    if conn.nil?
      conn = Faraday.new(url: parsed_response["url"]) do |f|
        f.request :multipart
      end
    end

    payload = parsed_response["fields"]
    payload['file'] = Faraday::FilePart.new(file, "application/pdf")
    upload = conn.post("/", payload)

    # Associate the record
    key = Nokogiri::XML(upload.body).xpath("//PostResponse/Key").first.content
    response = Faraday.post("#{API_HOST}/v1/patient_attachments", "{\"patient_id\": #{patient[0]}, \"upload_url\": \"#{parsed_response['url']}/#{key}\"}", HEADERS)

    if response.status == 201
      puts "Uploaded #{file}"
    else
      puts "Error uploading #{file}: #{response.body}"
    end

    # Avoid hitting Cliniko's limit of 200 uploads a minute
    sleep 0.3
  end
end
