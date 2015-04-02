#!/bin/ruby

require 'fileutils'
require 'nokogiri'
require 'pandoc-ruby'
require 'yaml'
require 'csv'

def html_clean(html)
  html.gsub(/ target="_blank"/, '')
end

def fix_links(md)
  matches = /^\[(\n+)\]: (.*)$/.match(md)
  # puts "MATCHES: #{matches.inspect}" if matches
  md
end

# Load configuration
config = YAML.load_file('config.yml')

# Defaults (TODO: extend configuration; have these settings be defaults)
path = '/tmp/mw2md-output'
authors_csv = 'authors.csv'
dump_xml = 'dump.xml'

puts "Prossing #{dump_xml}. Output directory: #{path}"

# Create git repo
FileUtils.mkdir_p path
`git init #{path}`

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
redirect = {}

mw.css('page').select { |page| page.css('redirect') }.each do |page|
  title = page.css('title').text
  redir = page.css('redirect').attr('title').text rescue ''

  next if title.match(/^File:/)

  unless redir.strip == ''
    # puts "Redirect! #{title} => #{redir}"
    redirect[title] = redir
  end
end

# Break all revisions out from being grouped into pages
revision = []

mw.css('page').sort_by { |page| page.css('timestamp').text }.each do |page|
  title = page.css('title').text.strip
  page_revisions = page.css('revision')

  next if title.match(/^File:/)

  authors = page.css('username').map { |u| u.text.downcase.strip }.sort.uniq

  final_revision = page_revisions.sort_by { |r| r.css('timestamp').text }.last

  page_revisions.each do |rev|
    revision.push page: page,
                  revision: rev,
                  final_revision: final_revision,
                  title: title,
                  authors: authors,
                  timestamp: rev.css('timestamp').text,
                  revision_count: page_revisions.count,
                  last_updated: page.css('timestamp').sort.last.text
  end
end

# Sort all revisions by time, process, and commit
number_of_pages = revision.count
current_page = 0

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

  category = wikitext_final.match(/\[\[Category\:([^\]]*)\]\]/i)
  category = category[1].strip if category.class == MatchData
  category_dirs = category.downcase.strip.split(/[|\/]/).first if category

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
    html = PandocRuby.convert(
      wikitext, :s, {
        from: :mediawiki,
        to:   :markdown_github
      },
      'atx-headers')
           .gsub(/__TOC__/, "* ToC\n{:toc}\n\n")
           .gsub(/__NOTOC__/, '{:.no_toc}')

      # Demote headings if there's an H1 already
      html.gsub!(/^#/, '##') if html.match(/^# /)
  rescue
    puts 'Error in conversion. Skipping to next page.'
    next
  end

  output = html
           .gsub(/\\([_#"'\$])/, '\\1')
           .gsub(/ "wikilink"\)/, ')')
           .gsub(/^- /, '* ')
           .gsub(/^`(.*)`$/, '      \\1')
           .gsub(/\[(\/\/[^ \]]*) ([^\]]*)\]/, '[\2](\1)') # handle // links
           .gsub(/(^\|+$)/, '') # Wipe out empty table rows

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

  frontmatter = metadata.select { |_, v| !v.nil? && !v.to_s.empty? }.to_yaml

  complete = "#{frontmatter}---\n\n# #{title_pretty}\n\n#{output}"

  ext = '.html.md'

  full_file = "#{dir.strip}/#{filename.strip}#{ext}"
              .downcase
              .squeeze(' ')
              .gsub(/[_\s:]/, '-')
              .gsub(/-+/, '-')
              .gsub(/["';]/, '')
              .squeeze('-')

  config['rewrite_full'].each do |k, v|
    # puts "BEFORE: #{full_file}"
    full_file.gsub!(Regexp.new(k, Regexp::IGNORECASE), v)
    # puts "AFTER: #{full_file}"
    dir = File.dirname full_file
  end

  percent = ((0.0 + current_page) / number_of_pages * 100).round(1)

  puts "Writing (#{current_page}/#{number_of_pages}) #{percent}% (MWID: #{id}) #{full_file}..."

  if wikitext.match(/^#REDIRECT/) || wikitext.strip.empty?
    puts "REDIRECTED! #{title} => #{redirect[title]}"
    begin
      File.delete "#{path}/#{full_file}"
    rescue
      puts "Error deleting file: #{path}/#{full_file}"
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

  unless comment.match(/^Created page with/) && redirect[title]
    git_author = wiki_author[username.downcase]
    git_name = git_author.nil? ? username.downcase : (git_author[:name] || username.downcase)
    git_name.gsub(/"/, "'")
    git_email = git_author.nil? ? "#{username.downcase}@wiki.conversion" : git_author[:email]
    git_comment = comment.strip.empty? ? "Updated #{title_pretty}" : comment.gsub(/"/, "'")
    git_comment = "Created #{title_pretty}" if comment.match(/^Created page with/)

    begin
      git_prefix = "cd #{path} && git --git-dir='#{path}/.git' --work-tree='#{path}'"
      git_postfix = ' && cd - '

      `#{git_prefix} add * #{git_postfix}`

      `#{git_prefix} commit -a --author="#{git_name} <#{git_email}>" --date="#{timestamp}" -m "#{git_comment}" #{git_postfix}`
    rescue
      puts "Error committing! #{out} :: #{out_add}"
    end
  end
end

# Output redirect mappings
File.write "#{path}/_redirects.yaml", redirect.to_yaml

# Clean up repo
`cd #{path} && git gc --aggressive && cd -`
