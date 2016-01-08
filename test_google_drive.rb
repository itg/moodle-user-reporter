# Install gems with `bundle install`

require 'rubygems'
require 'bundler/setup'  # Key to preventing httpi/rubyntlm version conflict!
require 'json'
require 'mandrill'
require 'tmpdir'
require 'zip'
require_relative 'google-drive'

# Initialize some configuration
config = JSON.parse(File.read('config.json'))

# Overwrite the recipients list for testing
config['recipients'] = ["mrice1@midmich.edu", "bkish@midmich.edu"]

mandrill = Mandrill::API.new(config['mandrill_key'])

google_drive = GoogleAPITool.new(config)
google_drive.debug = true

root = google_drive.find_or_create_folder_by(
            owner:config['google_drive_document_owner'],
            title:config['google_drive_root_folder_name'],
        parent_id:'root'
)

time_now = Time.now
today = time_now.strftime("%Y-%m-%d")
longer_today = time_now.strftime("%Y-%m-%d %H:%M:%S")
schools = [
    "Alma High School",
    "Beaverton High School",
    "Video Game High School"
]

schools.each do |school|
    puts "Working on #{school}..."
    school_folder = google_drive.find_or_create_folder_by(
            title:school,
        parent_id:root.id
    )
    school_date_folder = google_drive.find_or_create_folder_by(
            title:longer_today,
        parent_id:school_folder.id
    )

    io_string = Zip::OutputStream.write_buffer do |zio|
        zio.put_next_entry("1.txt")
        zio.write "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus luctus, mauris et luctus facilisis, neque dolor dapibus turpis, vel dignissim nisi nulla nec enim. Proin et gravida mi, eu pulvinar enim. Nam at erat eget odio convallis aliquet. Donec ipsum ex, lobortis et faucibus vestibulum, efficitur sed enim. Nulla consectetur pretium nibh vel congue. Aliquam congue est sit amet tortor cursus auctor. Nunc eu dapibus nisl, ut blandit ligula. Vestibulum quis vulputate purus, eget blandit neque."

        zio.put_next_entry("2.txt")
        zio.write "Vestibulum eget nisi id diam ullamcorper tincidunt nec vel metus. Pellentesque gravida orci justo, ac fringilla nibh aliquam ut. Vivamus mollis aliquam sem, a hendrerit erat facilisis id. Nulla feugiat tortor a orci varius, sed tempor lacus finibus. In ipsum nisi, congue ornare lectus quis, placerat aliquam felis. In feugiat maximus diam, a ornare augue semper in. Donec et nisi elementum, pharetra est id, facilisis lacus. Pellentesque consectetur rhoncus leo, ac gravida velit auctor nec. Mauris eu iaculis augue, non ultrices enim. Fusce porta ante in leo lacinia porttitor. Ut blandit sapien id venenatis iaculis."

        zio.put_next_entry("3.txt")
        zio.write "Suspendisse sed libero ut lacus tempus vulputate. Quisque sed lacinia dolor. Cras elit purus, tempor interdum eleifend eget, commodo vehicula massa. Pellentesque nec turpis vitae ipsum eleifend viverra. Ut in imperdiet urna, id aliquam diam. Nulla consequat pulvinar arcu quis lobortis. Suspendisse convallis pellentesque ex, eu dignissim risus. Pellentesque augue mi, laoreet et tortor in, commodo tempus neque. Pellentesque lacinia nisl metus, sed tempus justo lacinia vitae. Morbi tincidunt metus tincidunt, porta lacus eu, egestas risus."
        zio.put_next_entry("4.txt")
        zio.write "Curabitur porta vehicula egestas. Suspendisse consequat, justo at aliquam commodo, erat enim molestie magna, non pellentesque urna purus ac neque. Ut et tortor eget ipsum laoreet accumsan sed sit amet magna. Nunc fermentum ex justo, eu lobortis mi consectetur ac. Aliquam consequat velit at gravida imperdiet. Duis pulvinar interdum auctor. Nam a turpis nec turpis lacinia sollicitudin vel at enim. Pellentesque consectetur blandit ante, a auctor lacus scelerisque sed. Pellentesque accumsan ultrices mauris in consectetur. Donec id metus et arcu pretium tincidunt rutrum sed purus. Aenean posuere dignissim euismod. Aliquam non odio sed felis faucibus mattis sed et augue. Nullam orci erat, rhoncus ornare consequat et, bibendum et dui. Morbi ac sollicitudin leo."

        zio.put_next_entry("5.txt")
        zio.write "Donec vestibulum auctor magna eu feugiat. Curabitur vehicula orci sed dolor dapibus malesuada. Suspendisse vel varius lorem, quis lobortis enim. Integer eu elit sed sapien lobortis ornare. In nisi leo, vestibulum nec mattis quis, euismod sit amet arcu. Nullam non nisi sapien. Etiam aliquam est in tincidunt pellentesque. Cras vitae neque sollicitudin, efficitur nulla et, fermentum libero."

    end
    io_string.rewind

    fake_zip_file = Tempfile.new(school)
    begin
        fake_zip_file << io_string.sysread
        fake_zip_file.rewind

#         puts "Creating new file '#{today}-#{school}.text' as child of folder #{school_date_folder.title} (#{school_date_folder.id})"
        new_file = google_drive.create_file(
              parent_id:school_date_folder.id,
                  title:"#{today}-#{school}.zip",
            description:"Moodle User Reports for #{school} on #{today}",
              mime_type:'application/zip',
              file_name:fake_zip_file.path
        )

#         puts "All Reports for #{school}: #{school_folder.alternate_link}\n\tReports for #{longer_today}: #{school_date_folder.alternate_link}\n\t\tDownload: #{new_file.web_content_link}\n\t\tView in browser: #{new_file.alternate_link}"
    ensure
        fake_zip_file.close
        fake_zip_file.unlink
    end

  puts "Email will be sent to: #{config['recipients'].join(', ')}"

  # Convert the array of recipients to an array of structs for Mandrill
  recipients = []
  config['recipients'].each do |recipient|
    recipients << {"email" => recipient}
  end

  puts "Mandrill-friendly array of recipients:"
  puts recipients

  message = {
    "subject" => "[Testing]Moodle User Reports: #{today} #{school}",
#     "subject" => "Moodle User Reports: #{today} #{school}",
#     "html" => %(
# <p>Here are links to a collection of Moodle progress reports for #{school}.</p>
# #{config['disclaimer']}
# <ul>
#     <li>
#         <a target="_blank" href="#{school_folder.alternate_link}">All Reports for #{school}</a>
#         <ul>
#             <li>
#                 <a target="_blank" href="#{school_date_folder.alternate_link}">Reports for #{today}</a>
#                 <ul>
#                     <li><a target="_blank" href="#{new_file.web_content_link}">Download</a></li>
#                     <li><a target="_blank" href="#{new_file.alternate_link}">View in Browser</a></li>
#                 </ul>
#             </li>
#         </ul>
#     </li>
# </ul>
# <ul><li>#{labels.join('</li><li>')}</li></ul>
# ),
    "html" => %(
<p>Here are links to a collection of Moodle progress reports for #{school}.</p>
#{config['disclaimer']}
<ul>
    <li>
        <a target="_blank" href="#{school_folder.alternate_link}">All Reports for #{school}</a>
        <ul>
            <li>
                <a target="_blank" href="#{school_date_folder.alternate_link}">Reports for #{today}</a>
                <ul>
                    <li><a target="_blank" href="#{new_file.web_content_link}" style="background-color:reg(91,183,91);background-image:linear-gradient(rgb(98,196,98),rgb(81,163,81));background-repeat:repeat-x;border-bottom-color:rgba(0,0,0,0.247059);color:rgb(255,255,255);display:inline-block;border-bottom-left-radius:4px;border-bottom-right-radius:4px;border-bottom-style:solid;border-bottom-width:1px;border-image-outset:0px;border-image-repeat:stretch;border-image-slice:100%;border-image-source:none;border-image-width:1;border-left-color:rgba(0,0,0,0.0980392);border-left-style:solid;border-left-width:1px;border-right-color:rgba(0,0,0,0.0980392);border-right-style:solid;border-right-width:1px;border-top-color:rgba(0,0,0,0.0980392);border-top-left-radius:4px;border-top-right-radius:4px;border-top-style:solid;border-top-width:1px;box-shadow:rgba(255,255,255,0.2) 0px 1px 0px 0px inset, rgba(0,0,0,0.04705888) 0px 1px 2px 0px;line-bottom:20px;margin-bottom:0px;padding: 4px 12px;text-align:center;text-shadow:rgba(0,0,0,0.247059) 0px -1px 0px;vertical-align:middle;text-decoration:none;">Download All Reports</a></li>
                    <li><a target="_blank" href="#{new_file.alternate_link}">View Reports in Browser</a></li>
                </ul>
            </li>
        </ul>
    </li>
</ul>
),
    "from_email" => config['mandrill_account'],
    "to" => recipients,
    "headers" => {"Reply-To" => config['reply_to']},
    "tags" => ["moodle-user-reports", "testing"]}

#     abort "Did not send -- this time"
    result = mandrill.messages.send message
    puts "Received the following response from Mandrill:"
    puts result
end
