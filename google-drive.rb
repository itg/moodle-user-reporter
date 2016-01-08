# Install gems with `bundle install`

require 'google/api_client/auth/key_utils'
require 'google/api_client/auth/jwt_asserter'
require 'google/api_client'

class GoogleAPITool

    # Can be found here
    #   https://developers.google.com/apis-explorer/#s/
    API_VERSION = 'v2'


    # Defaults to false
    # If set to true, function calls will put extra information
    attr_accessor :debug

    def initialize(config = {})
        @debug = false

        # Which account owns the folders/files for this app
        owner                   = config['google_drive_document_owner']

        # API credential information
        # Can be found here:
        #   https://console.developers.google.com/project/mmcc-moodle-user-reporter/apiui/credential
        service_account_email   = config['google_api_service_email']
        key_file                = config['google_api_key_filename']
        key_secret              = config['google_api_key_password']

        # Users may see this information
        @application_name       = config['google_api_app_name']
        @application_version    = config['google_api_app_version']

        key = Google::APIClient::KeyUtils.load_from_pkcs12(key_file, key_secret)
        asserter = Google::APIClient::JWTAsserter.new(service_account_email, 'https://www.googleapis.com/auth/drive.file', key)

        @client = Google::APIClient.new(
            :application_name => @application_name,
            :application_version => @application_version,
        )

        @client.authorization = asserter.authorize(owner);

        @drive = @client.discovered_api('drive', API_VERSION)
    end

    def list_files(query:'', token:nil)
        if @client.nil? or @drive.nil?
           raise "#{self.name} is not properly initialized"
        end

        parameters = {}
        parameters['q'] = query
        if '' != token.to_s
            parameters['pageToken'] = token
        end

        if @debug
            puts "q: #{query}"
        end

        files = Array.new
        for n in 0..4
            result = @client.execute(
                :api_method => @drive.files.list,
                :parameters => parameters
            )
            if 200 == result.status
                # Got some files
                # Return the files and a token to get the next set to the caller
                files = result.data
                return files.items, files.next_page_token
            else
                if @debug
                    puts "An error occurred: #{result.data['error']['message']} (#{result.status})"
                end

                if false == self.exponential_backoff(n:n, status:result.status, reason:result.data['error']['errors'][0]['reason'])
                    return Array.new, nil
                end
            end
        end

        # This request should have succeeded by already
        # We should only reach here if the exponential backoff still did not resolve the issue
        if @debug
            puts "Failed to list files using query: #{query}"
        end
        return Array.new, nil
    end 

    def get_file(file_id = nil)
        return_value = nil
        if @client.nil? or @drive.nil?
           raise "#{self.name} is not properly initialized"
        end

        if file_id.nil?
            raise "Incorrect arguments passed"
        end

        for n in 0..4
            result = @client.execute(
                :api_method => @drive.files.get,
                :parameters => { 'fileId' => file_id })
            if 200 == result.status
                return result.data
            else
                if @debug
                    puts "Error fetching file (#{result.status}) - #{result.data['error']['message']}"
                end

                if false == self.exponential_backoff(n:n, status:result.status, reason:result.data['error']['errors'][0]['reason'])
                    return nil
                end
            end
        end

        # This request should have succeeded by already
        # We should only reach here if the exponential backoff still did not resolve the issue
        if @debug
            puts "Failed to fetch file #{file_id}"
        end
        return nil
    end

    # Puts out interesting file info
    def put_file_info(google_file:nil, level:0, walk_parents:false)
        if google_file.nil?
            return
        end
        puts '-' * level + "File: #{google_file.title} (#{google_file.id})"

        if google_file.methods.include? :mime_type
            puts "-" * level + "| MIME type #{google_file.mime_type}"
        end

        # E.g. Download
        if google_file.methods.include? :web_content_link
            puts "-" * level + "| web_content_link #{google_file.web_content_link}" 
        end

        if google_file.methods.include? :web_view_link
            puts "-" * level + "| web_view_link #{google_file.web_view_link}" 
        end

        # E.g. View in Browser
        if google_file.methods.include? :alternate_link
            puts "-" * level + "| alternate_link #{google_file.alternate_link}"
        end

        if google_file.methods.include? :owners
            puts
            google_file.owners.each do |owner|
                puts "-" * level + "| owner #{owner.displayName} (#{owner.permissionId})"
            end
        end

        if walk_parents
            # Check here (and not before) because the statements above do no use these objects
            if @client.nil? or @drive.nil?
               raise "#{self.name} is not properly initialized"
            end

            if google_file.methods.include? :parents
                puts
                google_file.parents.each do |parent|
                    puts "-" * level + "| parent found (#{parent.id})"
                    parent_file = self.get_file(parent.id)
                    if parent_file
                        # To understand recursion, you must first understand recursion
                        self.put_file_info(google_file:parent_file, level:(1+level), walk_parents:walk_parents)
                    end
                end
            end
        end

    end

    # Adapted from API Reference
    # https://developers.google.com/drive/v2/reference/files/insert
    ##
    # Create a new file
    #
    # @param [String] title
    #   Title of file to insert, including the extension.
    # @param [String] description
    #   Description of file to insert
    # @param [String] parent_id
    #   Parent folder's ID.
    # @param [String] mime_type
    #   MIME type of file to insert
    # @param [String] file_name
    #   Name of file to upload
    # @return [Google::APIClient::Schema::Drive::V2::File]
    #   File if created, nil otherwise
    def create_file( title:'', description:'', parent_id:nil, mime_type:'', file_name:'')
        if @client.nil? or @drive.nil?
           raise "#{self.name} is not properly initialized"
        end

        file = {
            'title' => title,
            'description' => description,
            'mimeType' => mime_type
        }

        if parent_id
            file.store("parents", [{'id' => parent_id }])
        end

        media = Google::APIClient::UploadIO.new(file_name, mime_type)
        for n in 0..4
            result = @client.execute(
                :api_method => @drive.files.insert,
                :body_object => file,
                :media => media,
                :parameters => {
                    'uploadType' => 'multipart',
                    'alt' => 'json'})
            if 200 == result.status
                # File created successfully
                return result.data
            else
                if @debug
                    puts "Error creating file (#{result.status}) - #{result.data['error']['message']}"
                end

                if false == self.exponential_backoff(n:n, status:result.status, reason:result.data['error']['errors'][0]['reason'])
                    return nil
                end
            end
        end

        # This request should have succeeded by already
        # We should only reach here if the exponential backoff still did not resolve the issue
        if @debug
            puts "Failed to create file #{title}"
        end
        return nil
    end

    # Used to handle server errors
    # Returns true if backoff was performed, false if not
    def exponential_backoff(n:0, status:200, reason:'')
        do_retry = false
        case status
            when 200
                if @debug
                    puts "Incorrect usage of exponential_backoff; do not call this when an API call returns a 200 status code! Returning true"
                end
                return true
            when 500..599
                do_retry = true
            when 403
                # Check for rate limiting message
                if ['rateLimitExceeded', 'userRateLimitExceeded'].include? reason
                    do_retry = true
                end
        end

        if do_retry
            if @debug
                puts "Retrying in #{1 << n} seconds..."
            end
            sleep((1 << n) + rand(1001) / 1000)
        end

        return do_retry
    end

    def create_folder( title:'', parent_id:nil)
        if @client.nil? or @drive.nil?
           raise "#{self.name} is not properly initialized"
        end

        file = {
            'title' => title,
            # Use a specific, special MIME type for folders
            'mimeType' => 'application/vnd.google-apps.folder',
        }
        if parent_id
            file.store("parents", [{'id' => parent_id }])
        end

        # Need to upload a new file (this one is empty) or the call does not work as expected
        # And by "not as expected" I mean it will upload a _file_ with type 'application/json' titled Untitled
        media = Google::APIClient::UploadIO.new(Tempfile.new('folder'), 'text/plain')
        for n in 0..4
            result = @client.execute(
                :api_method => @drive.files.insert,
                :body_object => file,
                :media => media,
                :parameters => {
                    # use 'multipart' because we are also uplading metadata
                    'uploadType' => 'multipart',
                    'visibility' => 'PRIVATE',
                    })
            if 200 == result.status
                # Folder created successfully
                return result.data
            else
                if @debug
                    puts "Error creating folder (#{result.status}) - #{result.data['error']['message']}"
                end

                if false == self.exponential_backoff(n:n, status:result.status, reason:result.data['error']['errors'][0]['reason'])
                    return nil
                end
            end
        end

        # This request should have succeeded by already
        # We should only reach here if the exponential backoff still did not resolve the issue
        if @debug
            puts "Failed to create folder #{title}"
        end
        return nil
    end

    def find_or_create_folder_by( title:'', parent_id:nil, owner:'', error_on_multiple:false)
        if @client.nil? or @drive.nil?
           raise "#{self.name} is not properly initialized"
        end

        query = "mimeType = 'application/vnd.google-apps.folder' and title contains '#{title}'"
        if '' != parent_id.to_s
            query = "#{query} and '#{parent_id}' in parents"
        end
        if '' != owner.to_s
            query = "#{query} and '#{owner}' in owners"
        end

        folder_list = Array.new
        page_token = nil

        begin
            folders, next_page_token = self.list_files(query:query, token:page_token)
            folder_list.concat(folders)

            if @debug
                if '' == page_token.to_s
                    puts "Got #{folders.count} file(s)"
                else
                    puts "Got #{folders.count} more file(s)"
                end
            end

            page_token = next_page_token

        end while '' != page_token.to_s

        if 1 > folder_list.count
            folder = self.create_folder(title:title, parent_id:parent_id)
        else
            if 1 < folder_list.count and error_on_multiple
                raise "Multiple folders exist! Query '#{query}'"
            else
                # Arbitrarily pick the first result
                folder = folder_list[0]
            end
        end

        return folder
    end
end
