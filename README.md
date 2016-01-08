# moodle-user-reporter

This Ruby script downloads grade and activity reports from Moodle for all dual enrolled high school students. Reports are zipped up by school, uploaded to Google Drive, and emailed to Student Services to share with high school counselors.

## History

This project came about because manually generating the reports for even a few students was time consuming, error-prone, and repetitive.

1. The earliest version of this project used the [Fake](http://fakeapp.com/) Mac web browser and a hard coded JSON configuration file to download reports for a subset of users.
2. Version 2.0 pulled data from the SMART database and useed the Mechanize gem to browse Moodle much more quickly.
3. Version 3.0 changed how the zipped files were stored: instead of being emailed out, the files are uploaded to Google Drive and links to the files are emailed. We are using a slightly out-of-date version of the Google API for Ruby because the newest version has not yet ported all of the needed functionality from the 0.8.6 release.
4. Version 3.5 changed what was uploaded: instead of uploading a single ZIP file to Google Drive, each individual report (now formatted as a PDF) is uploaded instead. There were also a few other updates in this version:
  * Gradebook feedback comments are redacted in the reports
  * Students must be opt-ed in to receive reports


## Requirements

1. `rbenv` for managing Ruby versions
2. Ruby 2.2.0 or higher
3. Bundler -- `gem install bundler`
4. zip installed (e.g. `sudo apt-get install zip`)
5. wkhtmltopdf installed<br/>
    To get the latest version on Ubuntu 12.04, you need to [download the latest .deb from here](http://wkhtmltopdf.org/downloads.html)
    1. `wget http://download.gna.org/wkhtmltopdf/0.12/0.12.2.1/wkhtmltox-0.12.2.1_linux-precise-amd64.deb`
    2. `sudo dpkg -i wkhtmltox-0.12.2.1_linux-precise-amd64.deb`<br/>
    Check to make sure you have a compatible version (it should mention patched qt)
    3. `wkhtmltopdf --version`<br/>
        Output should look like `wkhtmltopdf 0.12.2.1 (with patched qt)`


## Dependencies

Gems:

- `json`
- `mysql2`
- `mandrill-api` (provides `mandrill` library)
- `mechanize`
- `nokogiri` (for manipulating the HTML prior to converting to PDF)
- `pdfkit` (for converting HTML to PDFs - requires `wkhtmltopdf`)
- `google-api-client`, `0.8.6` (provides a Ruby implementation for the Google Drive v2 API)

You can install all of these gems with Bundler:

```
bundle install
```

## How to run

Run the program:

```ruby prototype.rb```

Or run the program and direct output to a log file:

```ruby prototype.rb > log.txt```

## Scheduling

The goal is to run this program every Friday morning after the Moodle course archives are complete. In 2015WI, 1,400+ enrollments (two reports each) took about 25-40 minutes to process.

This program is safe to run between semesters and during semesters without dual enrollments. All MySQL queries can return 0 rows, and Ruby will safely skip unnecessary loops when empty results/arrays are returned from the database.

Here's a sample crontab entry for this program from Brandon's iMac:

```
21 10 * * 5 ~/Source/moodle-user-reporter/launch_moodle_user_reporter.sh >>log.txt 2>&1
```

Use [cron checker](http://www.crOnchecker.net/) to explain the above sample. :)

## Things that may change between Moodle versions

1. Print styles
2. URLs to reports
3. Login form
4. Database schema (unlikely for mdl_user and mdl_course - id, idnumber)
