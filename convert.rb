#!/bin/ruby

require 'fileutils'
require 'nokogiri'
require 'pandoc-ruby'
require 'yaml'
require 'csv'
require 'shellwords'
require 'ruby-progressbar'
require 'wikicloth'
require 'kramdown'
require 'fuzzystringmatch'
require 'active_support'

# Restrict WikiCloth's escaping to just 'nowiki' tags
# and do so without a Ruby warning about chaging constants
orig_verbosity = $VERBOSE
$VERBOSE = nil
WikiCloth::WikiBuffer::HTMLElement.const_set(:ESCAPED_TAGS, ['nowiki'])
$VERBOSE = orig_verbosity

# Load configuration
config = YAML.load_file('config.yml')

# Load settings, fall back to defaults otherwise
path = config['output'] || '/tmp/mw2md-output'
authors_csv = config['authors_csv'] || 'authors.csv'
dump_xml = config['wiki_xml'] || 'dump.xml'
history = config['history'].nil? ? true : config['history']

fuzzymatch = FuzzyStringMatch::JaroWinkler.create(:pure)

# Functions (TODO: Move to a library file)

def fix_headings html, offset = 0
  heading_depth = html.scan(/^(#+ ).*/) || ['']
  heading_depth = heading_depth.map { |c| c.first.strip.length }
  heading_depth.pop

  return html if heading_depth.min.nil? || heading_depth.min <= 1 + offset

  hash = "#" * (heading_depth.min - 1)
  hash_offset = "#" * offset
  html.gsub(/^#{hash}(#?) (.*)/, "#{hash_offset}\\1 \\2")
end

# Begin the logic

errors = {}

puts "Prossing #{dump_xml}. Output directory: #{path}"

# Create git repo
FileUtils.mkdir_p path
Process.wait Kernel.spawn('git init .', chdir: path) if history

# Open and process MediaWiki dump
mw_xml = open dump_xml
mw = Nokogiri::XML(mw_xml)

# Authors
wiki_author = {}

CSV.foreach(authors_csv) do |col|
  wiki_author[col[0].downcase] = { name: col[1], email: col[2] }
  wiki_author[col[0].downcase][:name] = col[0] if col[1].to_s.strip == ''
end

# Discover all redirects
redirect = { wiki_redirects: {}, map: {} }

mw.css('page').select { |page| page.css('redirect') }.each do |page|
  title = page.css('title').text
  redir = page.css('redirect').attr('title').text rescue ''

  next if title.match(/^File:/)
  next if title.match(Regexp.new(config['skip'], Regexp::IGNORECASE))

  unless redir.strip == ''
    # puts "Redirect! #{title} => #{redir}"
    redirect[:wiki_redirects][title] = redir
  end
end

# Break all revisions out from being grouped into pages
revision = []

mw.css('page').each do |page|
  title = page.css('title').text.strip
  page_revisions = page.css('revision')

  next if title.match(/^File:/)
  next if title.match(Regexp.new(config['skip'], Regexp::IGNORECASE))

  authors = page.css('username').map { |u| u.text.downcase.strip }.sort.uniq

  final_revision = page_revisions.sort_by { |r| r.css('timestamp').text }.last

  revision_count = page_revisions.count
  page_revisions = [final_revision] unless history

  page_revisions.each do |rev|
    revision.push page: page,
                  revision: rev,
                  final_revision: final_revision,
                  title: title,
                  authors: authors,
                  timestamp: rev.css('timestamp').text,
                  revision_count: revision_count,
                  last_updated: page.css('timestamp').sort.last.text
  end
end

# Sort all revisions by time, process, and commit
number_of_pages = revision.count
current_page = 0

progress = ProgressBar.create format: '%a |%e |%b>%i| %p%% %t',
                              smoothing: 0.7,
                              throttle_rate: 1.0,
                              total: number_of_pages

revision.sort_by { |r| r[:timestamp] }.each do |rev_info|
  current_page += 1

  rev = rev_info[:revision]
  title = rev_info[:title]
  authors = rev_info[:authors]

  wikitext = rev.css('text').text
  wikitext_final = rev_info[:final_revision].css('text').text

  id = rev.css('id').text
  timestamp = rev.css('timestamp').text
  username = rev.css('username').text
  comment = rev.css('comment').text.gsub(/\/\*|\*\//, '').strip
  dirs = title.gsub(/&action=.*/, '').downcase.split(/[:\/]/)
  filename = dirs.pop.gsub(/&/, ' and ')
  dirs = dirs.join('/').strip
  dirs = nil if dirs.empty?

  category_match = /\[\[Category\:([^\]]*)\]\]/i
  category = wikitext_final.match(category_match)
  category = category[1].strip if category.class == MatchData
  category_dirs = category.downcase.strip.split(/[|\/]/).first if category

  # Wipe category text from the MediaWiki source so it's not converted
  # in-page (however, it's still preserved in metadata, thanks to above)
  wikitext_final.gsub!(category_match, '') if category

  category_match = nil

  config['catmatch'].each do |k, v|
    next if category_match
    category_match = v if filename.match(Regexp.new k)
  end

  config['rewrite_file'].each do |k, v|
    filename.gsub!(Regexp.new(k), v)
  end

  dir = category_match || category_dirs || dirs || 'uncategorized'

  config['rewrite_dir'].each do |k, v|
    dir.gsub!(Regexp.new(k), v)
  end

  if title.match(/^(home|main page)$/i)
    dir = ''
    filename = 'index'
  end

  dir.gsub!(/[_\s:]/, '-')
  dir.strip! if dir

  # Rewrite some wiki constructs into HTML, to be processed into Markdown
  config['rewrite_wiki'].each do |k, v|
    wikitext.gsub!(Regexp.new(k), v)
  end

  begin
    markdown = PandocRuby.convert(
      wikitext, :s, {
        from: :mediawiki,
        to:   :markdown_github
      },
      'atx-headers')
    conversion_error = false
  rescue
    begin
      # Fallback conversion, as pandoc bailed on us

      # Invoke WikiCloth
      wikicloth = WikiCloth::Parser.new(data: wikitext).to_html

      # Pass the WikiCloth HTML to Nokogiri for additional processing
      wiki_html = Nokogiri::HTML::DocumentFragment.parse(wikicloth)

      # Remove various MediaWiki-isms
      wiki_html.css('#toc').remove
      wiki_html.css('.editsection').remove
      wiki_html.css('a[name]').each { |n| n.remove if n.text.empty? }
      wiki_html.css('.mw-headline').each { |n| n.replace n.text }

      # Simplify tables (to increase the liklihood of conversion)
      wiki_html.css('table,tr,th,td').each do |n|
        n.keys.each { |key| n.delete(key) unless key.match(/span/) }
      end

      # Call upon Pandoc again, but this time with scrubbed HTML
      markdown = PandocRuby.convert(
        wiki_html, :s, {
          from: :html,
          to:   :markdown_github
        },
        'atx-headers')
    rescue
      puts "Error converting #{title}. Fallback even failed. #sadface"
      errors[title.to_s] = wikitext
      next
    end

    conversion_error = true
  end

  next unless markdown

  # Demote headings if H1 exists
  markdown.gsub!(/^#/, '##') if markdown.match(/^# /)

  # Clean up generated Markdown
  output = markdown
           .gsub(/__TOC__/, "* ToC\n{:toc}\n\n") # Convert table of contents
           .gsub(/__NOTOC__/, '{:.no_toc}') # Handle explicit no-ToC
           .gsub(/\\([_#"'<>$])/, '\\1') # Unescape overly-escaped
           .gsub(/ "wikilink"\)/, ')') # Remove wikilink link classes
           .gsub(/^- /, '* ') # Change first item of bulleted lists
           .gsub(/^`(.*)`$/, '      \\1') # Use indents for blockquotes
           .gsub(/\[(\/\/[^ \]]*) ([^\]]*)\]/, '[\2](\1)') # handle // links
           .gsub(/(^\|+$)/, '') # Wipe out empty table rows

  # Custom markdown rewriting rules
  config['rewrite_markdown'].each do |k, v|
    output.gsub!(Regexp.new(k), v)
  end

  title_pretty = title.split(/[:\/]/).pop

  metadata = {
    'title'         => title_pretty,
    'category'      => category_match || category_dirs,
    'authors'       => authors.join(', '),
    'wiki_category' => category,
    'wiki_title'    => title,
    'wiki_revision_count' => rev_info[:revision_count],
    'wiki_last_updated' => Date.parse(rev_info[:last_updated])
    # 'wiki_date' => Date.parse(timestamp)
    # "wiki_id"       => id
  }

  # Add frontmatter based on matchers from config
  # (matchers apply to wiki source, which has data the conversion lacks)
  config['frontmatter'].each do |k, v|
    matches = wikitext.gsub(/<!\-\-[^\-\->]*\-\->/m, '').match(Regexp.new k)
    metadata[v] = matches.captures.join(', ').squeeze(' ').strip if matches
  end

  if conversion_error
    metadata['wiki_conversion_fallback'] = true
    metadata['wiki_warnings'] = 'conversion-fallback'
  end

  config['warnings'].each do |k, v|
    if wikitext.gsub(/<!\-\-[^\-\->]*\-\->/m, '').match(Regexp.new k)
      warnz = metadata['wiki_warnings'].to_s.split(/, /)
      metadata['wiki_warnings'] = warnz.push(v).uniq.join(', ')
    end
  end

  frontmatter = metadata.select { |_, v| !v.nil? && !v.to_s.empty? }.to_yaml

  headings = output.match(/^#+ (.*)/)

  heading_diff = if headings
                   fuzzymatch.getDistance(title_pretty, headings[1])
                 else
                   0
                 end


  if heading_diff >= 0.75
    # The existing heading is similar enough to the page title
    complete = "#{frontmatter}---\n\n#{fix_headings output}"
  else
    # Add cleaned up title as a heading
    title_prettier = if title.match(/ /)
                       title_pretty
                     else
                       title_pretty
                       .gsub(/([a-z])([A-Z0-9])/, '\1 \2')
                       .gsub(/([A-Z])([A-Z])([a-z])/, '\1 \2\3')
                     end

    complete = "#{frontmatter}---\n\n# #{title_prettier}\n\n#{fix_headings output, 1}"
  end

  ext = '.html.md'

  full_file = "#{dir.strip}/#{filename.strip}#{ext}"
              .downcase
              .squeeze(' ')
              .gsub(/[_\s:]/, '-')
              .gsub(/-+/, '-')
              .gsub(/["';]/, '')
              .squeeze('-')

  config['rewrite_full'].each do |k, v|
    full_file.gsub!(Regexp.new(k, Regexp::IGNORECASE), v)
    dir = File.dirname full_file
  end

  # Update progressbar
  progress.increment

  if wikitext.match(/^#REDIRECT/) || wikitext.strip.empty?
    # puts "REDIRECTED! #{title} => #{redirect[title]}"
    begin
      File.delete "#{path}/#{full_file}"
    rescue
      # puts "Error deleting file: #{path}/#{full_file}"
    end
  else
    begin
      FileUtils.mkdir_p "#{path}/#{dir}"
    rescue
      puts "Error creating directory! #{path}/#{dir}"
    end

    begin
      File.write "#{path}/#{full_file}", complete
    rescue
      puts "Error writing file! #{path}/#{full_file} — #{frontmatter.inspect}"
    end
  end

  # Add document path info to the redirect file, in mappings
  redirect[:map][title] = full_file.chomp(ext)

  # Add to git (when history is preserved)
  unless comment.match(/^Created page with/) && redirect[title] || !history
    git_author = wiki_author[username.downcase]
    git_name = git_author.nil? ? username.downcase : (git_author[:name] || username.downcase)
    git_email = git_author.nil? ? "#{username.downcase}@wiki.conversion" : git_author[:email]
    git_comment = comment.strip.empty? ? "Updated #{title_pretty}" : comment
    git_comment = "Created #{title_pretty}" if comment.match(/^Created page with/)

    # Shell-escape strings before they hit the command line
    git_comment = Shellwords.escape git_comment
    git_author = Shellwords.escape "#{git_name} <#{git_email}>"

    command = 'git add * && git commit -q -a ' \
      "--author=#{git_author} --date='#{timestamp}' -m #{git_comment}" \
      ' &> /dev/null'

    begin
      Process.wait Kernel.spawn(command, chdir: path)
    rescue
      puts 'Error committing!'
    end
  end
end

progress.finish

if errors
  FileUtils.mkdir_p 'errors/'
  errors.each do |fname, text|
    filename_clean = fname.gsub(/[:\/<>&]/, '').squeeze(' ').gsub(/[: ]/, '_')
    File.write "errors/#{filename_clean}.html.md", text
  end
end

puts 'Conversion done!'

puts "#{errors.count} error#{errors.count != 1 ? 's' : ''} " \
  'found, and saved in ./errors/' if errors.count > 0

# Output redirect mappings
File.write "#{path}/redirects.yaml", redirect.to_yaml

# Clean up repo
if history
  puts 'Re-packing repo:'
  Process.wait Kernel.spawn('git gc --aggressive', chdir: path)
end
