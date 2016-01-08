# Install gems with `bundle install`

require 'rubygems'
require 'bundler/setup'  # Key to preventing httpi/rubyntlm version conflict!
require 'json'
require 'mysql2'
require 'mandrill'
require 'base64'
require 'mechanize'
require 'slack-notifier'
require 'pdfkit'
require 'nokogiri'
require_relative 'google-drive'

# Handy dandy run time variables
current_script = File.basename($0, File.extname($0)) 
today = Time.now.strftime("%Y-%m-%d")
longer_today = Time.now.strftime("%Y-%m-%d %H:%M:%S")

# Create a global ($) empty MySQL connection so we can escape arrays of strings before joining them in queries
$shared_client = Mysql2::Client.new()
def escape(array_to_escape = [])
  #puts "Before: #{array_to_escape}"
  # map vs map! -- map! will modify an array in place
  array_to_escape.map! { |element| $shared_client.escape(element) }
  #puts "After: #{array_to_escape}"
end

# Initialize some configuration
config = JSON.parse(File.read('config.json'))

# Overwrite the recipients list for testing
# config['recipients'] = ["mrice1@midmich.edu", "bkish@midmich.edu"]

css = File.read(config['stylesheet'])
mandrill = Mandrill::API.new(config['mandrill_key'])

# Set up Google Drive API object
google_drive = GoogleAPITool.new(config)
google_drive.debug = true

# Go go gadget browser
agent = Mechanize.new

# Connect to SMART
smart = Mysql2::Client.new(host: config['smart_db_host'], 
	                       username: config['smart_db_username'], 
	                       password: config['smart_db_password'], 
	                       database: config['smart_db'])

# Connect to Moodle
moodle = Mysql2::Client.new(host: config['moodle_db_host'], 
	                        username: config['moodle_db_username'], 
	                        password: config['moodle_db_password'], 
	                        database: config['moodle_db'])

# Connect to Slack (global var)
$slack = Slack::Notifier.new(config['slack_webhook_url'])

def logger(message)
  puts "#{Time.now} #{message}"
  $slack.ping(message)
end

# Pass a block of code to this function to automatically try multiple times before giving up
def trythreetimes
  tries = 0
  begin
    yield
  rescue Exception => e  
    tries += 1
    logger "Error: #{e.message}"
    if tries < 3
      logger "Waiting 5 seconds and trying again..."
      sleep(5)
      retry
    end
    logger "Giving up and ending program!"
    abort
  end
end

# Without further ado...
logger "Starting #{current_script}"

# Step 1: Create the directory for saving the reports
system 'mkdir', '-p', today

# Step 1.1: Ensure the Google Drive folder for saving the reports exists
root = google_drive.find_or_create_folder_by( owner:config['google_drive_document_owner'], title:config['google_drive_root_folder_name'], parent_id:'root')

# Step 2: What terms are happening? No MTEC terms, please!
terms = []
sql = "SELECT name FROM terms WHERE CURDATE() >= `start` AND CURDATE() <= `end` AND name NOT LIKE '%MT'"
#puts sql
smart.query(sql).each do |row|
  terms << row['name']
end
escape(terms)

puts "Current terms: #{terms}"

# Step 3: What schools are getting reports?
schools = []
sql = "SELECT DISTINCT(sponsor_name) FROM dual_enrollment_statuses WHERE term IN ('#{terms.join("','")}') ORDER BY sponsor_name"
#puts sql
smart.query(sql).each do |row|
  schools << row['sponsor_name']
end
escape(schools)

puts "Schools for this term: #{schools}"

# Step 4: Log into Moodle
page = trythreetimes { agent.get(config['moodle_url']) }
page = trythreetimes { agent.page.link_with!(text: 'Click here ...', href: /NOCAS/).click }
#pp page
login_form = page.forms.first
login_form.username = config['moodle_username']
login_form.password = config['moodle_password']
page = trythreetimes { agent.submit(login_form) }

# Step 5: Prepare SQL statements for each high school
school_queries = []
cached_enrollments = []
schools.each do |school|
  query = "
SELECT
  u.id as user_id,
  u.lastname,
  u.firstname,
  c.synonym,
  c.subject,
  c.course,
  c.section
FROM
  dual_enrollment_statuses d
  INNER JOIN users u ON d.user_id = u.id
  INNER JOIN student_memberships sm ON d.user_id = sm.user_id
  INNER JOIN course_sections c ON sm.course_section_id = c.id
  INNER JOIN userreporter_included_students i ON i.term = d.term AND i.student_id = sm.user_id
WHERE
  d.term IN ('#{terms.join("','")}') AND
  d.sponsor_name = '#{school}' AND
  c.term IN ('#{terms.join("','")}') AND
  sm.drop_date IS NULL
ORDER BY
  u.lastname,
  u.firstname,
  c.subject,
  c.course,
  c.section
"
  school_queries << query

# Step 5.1: Gather all enrollments before starting reporting
  #puts sql
  enrollments = []
  smart.query(query).each do |row|
    enrollments << row
  end

  cached_enrollments << enrollments
end

# Step 6: Loop through enrollments and do Moodle stuff!
for i in 0...schools.size
  # Pluck the next school and its query
  school = schools[i]

  # Ensure the school has a Google Drive folder
  school_folder = google_drive.find_or_create_folder_by( title:school, parent_id:root.id)

  # Ensure there is a date/time stamped subfolder for this run
  school_date_folder = google_drive.find_or_create_folder_by( title:longer_today, parent_id:school_folder.id)

  school_enrollments = cached_enrollments[i]
  puts "Found #{school_enrollments.size} enrollments for #{school}"

  # Pluck out information for querying Moodle in two big batches -- all values will be returned as numbers, so no need to further escape them!
  school_user_ids = school_enrollments.map { |hash| hash['user_id'] }.uniq
  school_synonyms = school_enrollments.map { |hash| hash['synonym'] }.uniq
  puts "Found #{school_user_ids.size} users in #{school_synonyms.size} sections"

  # Build look-up table of user_id -> moodle_user_id
  moodle_user_lookup = {}
  user_sql = "SELECT TRIM(LEADING '0' FROM idnumber) AS user_id, id AS moodle_user_id FROM mdl_user WHERE TRIM(LEADING '0' FROM idnumber) IN ('#{school_user_ids.join("','")}')"
  moodle.query(user_sql).each do |row|
    moodle_user_lookup[row['user_id']] = row['moodle_user_id']
  end
  
  # Build look-up table of synonym -> moodle_course_id (newest shell created will overwrite in case of duplicates)
  moodle_course_lookup = {}
  course_sql = "SELECT idnumber AS synonym, id AS moodle_course_id FROM mdl_course WHERE idnumber IN ('#{school_synonyms.join("','")}')"
  moodle.query(course_sql).each do |row|
    moodle_course_lookup[row['synonym']] = row['moodle_course_id']
  end

  # Now it's time to save the reports!
  labels = []
  files = []

  school_enrollments.each do |e|
    moodle_user_id = moodle_user_lookup[e['user_id'].to_s]
    moodle_course_id = moodle_course_lookup[e['synonym'].to_s]

    if moodle_user_id.nil? or moodle_course_id.nil?
        logger("No Moodle user_id found for user id '#{e['user_id']}'") if moodle_user_id.nil?
        logger("No Moodle course_id found for synonym '#{e['synonym']}'") if moodle_course_id.nil?

        # If either of the two parameters are invalid, skip to the next enrollment
        next
    end

    # puts "#{e['firstname']} #{e['lastname']} (#{e['user_id']}) in #{e['synonym']}"
    # puts "  Moodle user ID: #{moodle_user_id}, Moodle course ID: #{moodle_course_id}"

    urls = {}
    urls["gradebook"] = "#{config['moodle_url']}/grade/report/user/index.php?id=#{moodle_course_id}&userid=#{moodle_user_id}"
    urls["activity"] = "#{config['moodle_url']}/report/outline/user.php?id=#{moodle_user_id}&course=#{moodle_course_id}&mode=outline"

    urls.each do |suffix, url|
      label = "#{e['lastname']}#{e['firstname']}-#{e['subject']}#{e['course']}#{e['section']}-#{suffix}"
      file_path = "#{today}/#{today}-#{label}.pdf"

      puts "Visiting #{url}"
      page = trythreetimes { agent.get(url) }

      #################### Nokogiri behaved unexpectedly

      # Capture the page so we can manipulate
      html = Nokogiri::HTML(page.content)

      xpath = []
      # Remove embedded/linked files hosted at // since these don't work when HTML files are opened locally
      #   Sample: <link href="//fonts.googleapis.com/css?family=Oswald" rel="stylesheet" type="text/css">
      xpath << "//link[starts-with(@href, '//')]"

      # Remove a pesky inline style on grade book user reports
      #   Sample: <p style="page-break-after: always;"></p>
      #   Alternate XPath: '//p[contains(@style,"page-break-after") and contains(@style,"always")]'
      xpath << '//p[@style="page-break-after: always;"]'

      xpath.each do |selector|
          html.search(selector).each do |element|
            element.remove
          end
      end

      # From a comment on this Stack Overflow answer
      #     http://stackoverflow.com/a/4511618
      nbsp = 160.chr(Encoding::UTF_8)

      the_replacements = []
      # Remove Feedback column header
      #the_replacements << ['th.column-feedback', '']

      # Replace Feedback with boilerplate
      the_replacements << ['td.column-feedback.feedbacktext', '[Contact Student to see feedback]']

      the_replacements.each do |selector,new_content|
          html.css(selector).each do |element|
              # Only redact actual feedback -- if the instructor has not left feedback, leave it alone!
              element.content = new_content unless element.content.to_s.empty? or nbsp == element.content
          end
      end

      # Inject print styles directly into the page
      head = html.at("//head")
      head.inner_html += css

      # Done processing -- return processed HTML
      html = html.to_html
      #################### End Nokogiri

      # We're done manipulating the HTML, time to output a shiny PDF!
      kit = PDFKit.new(html, page_size: 'Letter', disable_smart_shrinking: true, zoom: 0.5, background: true)
      kit.to_file(file_path)

      puts "Saved #{file_path}"

      labels << label
      files << file_path

      # Upload PDF to Google Drive
      new_file = google_drive.create_file(
          parent_id:school_date_folder.id,
          title:label,
          description:"Moodle User #{suffix.capitalize} Report for #{e['firstname']} #{e['lastname']} for #{school} on #{today}",
          mime_type:'application/pdf',
          file_name:file_path)

    end # end urls

  end # end school enrollments

  puts "Email will be sent to: #{config['recipients'].join(', ')}"

  # Convert the array of recipients to an array of structs for Mandrill
  recipients = []
  config['recipients'].each do |recipient|
    recipients << {"email" => recipient}
  end

  puts "Mandrill-friendly array of recipients:"
  puts recipients

  message = {
    "subject" => "Moodle User Reports: #{today} #{school}",
    "html" => %(
<p>Here are links to a collection of Moodle progress reports for #{school}.</p>
#{config['disclaimer']}
<p>View Reports in Google Drive</p>
<ul>
    <li>
        <a target="_blank" href="#{school_folder.alternate_link}">All Reports for #{school}</a>
        <ul>
            <li>
                <a target="_blank" href="#{school_date_folder.alternate_link}">Reports for #{today}</a>
                <ul>
                    <li>#{labels.join('</li><li>')}</li>
                </ul>
            </li>
        </ul>
    </li>
</ul>
),
    "from_email" => config['mandrill_account'],
    "to" => recipients,
    "headers" => {"Reply-To" => config['reply_to']},
    "tags" => ["moodle-user-reports"]}

  result = mandrill.messages.send message
  logger "Email for #{school} sent"
  puts "Received the following response from Mandrill:"
  puts result

end # end schools

number_pdf_files = `ls -l #{today}/*.pdf | wc -l`.strip

puts "Deleting saved pdf files (zip files will be kept)..."
cleanup_command = "rm -f #{today}/*.pdf"
puts "  #{cleanup_command}"
puts `#{cleanup_command}`

logger "#{number_pdf_files} PDF reports were generated for #{schools.size} schools"

logger "Finished #{current_script}"
